// Vulkan backend (Linux).
//
// The same single instanced draw as the Direct3D 11 and Metal backends, with
// the same shading (ui.glsl is a port of ui.metal), so all three look
// identical. The instance array is the vertex buffer, stepped per instance,
// as on Direct3D 11. The presentation choices mirror the other backends':
//
// - With vsync and VK_KHR_present_wait, renderer_wait_for_frame blocks until
//   the frame before the last is on screen: one frame queued at most, which
//   is what the frame latency waitable does on Windows and the presented
//   handler on macOS. We wait *before* reading input and building the UI, so
//   what is shown is never more than a frame old. Without present_wait, the
//   wait is for the GPU to finish the frame before the last.
// - FIFO with vsync; without, IMMEDIATE (tearing allowed, and variable
//   refresh in fullscreen), else MAILBOX.
// - Three frames in flight, each with its own command buffer, fence and
//   instance buffer, since the CPU writes the next frame's instances while
//   the GPU may still read the last two.
//
// libvulkan.so.1 is loaded at run time, and every Vulkan procedure comes
// through vkGetInstanceProcAddr, so the executable doesn't link it. The
// shaders are compiled at build time (build.jai runs glslc) and embedded as
// shader_ui_vert and shader_ui_frag.

renderer_init :: () -> bool {
    if !load_vulkan() return false;
    if !create_instance() return false;
    if !create_surface() return false;
    if !pick_device() return false;
    if !create_device() return false;
    if !create_pipeline() return false;
    if !create_frames() return false;
    if !create_swapchain() return false;
    log("Vulkan device: % (present wait: %)\n", vk.device_name, ifx vk.present_wait then "yes" else "no");
    return true;
}

renderer_shutdown :: () {
    if vk.device {
        vk_call.DeviceWaitIdle(vk.device);
        destroy_swapchain_parts();
        if vk.swapchain vk_call.DestroySwapchainKHR(vk.device, vk.swapchain, null);
        for * vk.frames {
            destroy_buffer(*it.instances);
            destroy_buffer(*it.staging);
            for * image: it.garbage destroy_atlas_image(image);
            array_free(it.garbage);
            if it.fence    vk_call.DestroyFence(vk.device, it.fence, null);
            if it.acquired vk_call.DestroySemaphore(vk.device, it.acquired, null);
        }
        destroy_atlas_image(*vk.glyph_atlas);
        destroy_atlas_image(*vk.color_atlas);
        destroy_buffer(*vk.capture);
        if vk.command_pool    vk_call.DestroyCommandPool(vk.device, vk.command_pool, null);
        if vk.descriptor_pool vk_call.DestroyDescriptorPool(vk.device, vk.descriptor_pool, null);
        if vk.pipeline        vk_call.DestroyPipeline(vk.device, vk.pipeline, null);
        if vk.pipeline_layout vk_call.DestroyPipelineLayout(vk.device, vk.pipeline_layout, null);
        if vk.set_layout      vk_call.DestroyDescriptorSetLayout(vk.device, vk.set_layout, null);
        if vk.sampler         vk_call.DestroySampler(vk.device, vk.sampler, null);
        if vk.render_pass     vk_call.DestroyRenderPass(vk.device, vk.render_pass, null);
        vk_call.DestroyDevice(vk.device, null);
    }
    if vk.surface  vk_call.DestroySurfaceKHR(vk.instance, vk.surface, null);
    if vk.instance vk_call.DestroyInstance(vk.instance, null);
    array_free(vk.images);
    array_free(vk.views);
    array_free(vk.framebuffers);
    array_free(vk.rendered);
    vk = .{};
}

// One wait per present: until the next present, waiting again does nothing.
renderer_wait_for_frame :: () {
    if vk.waited return;
    vk.waited = true;
    if !vk.device || !vk.swapchain return;

    // The frame before the last on screen: at most one frame queued.
    if vk.vsync && vk.present_wait && seconds_since_init() >= vk.present_wait_paused_until
       && vk.submitted >= vk.swapchain_first_id + 1 {
        result := vk_call.WaitForPresentKHR(vk.device, vk.swapchain, vk.submitted - 1, PRESENT_WAIT_TIMEOUT);
        if result == .SUCCESS return;
        // A window that isn't shown never presents (hidden, minimized, on
        // another workspace): pace on the GPU for a while instead, and at
        // most at the refresh rate, since MAILBOX (Wayland) wouldn't hold
        // frames back.
        if result == .TIMEOUT vk.present_wait_paused_until = seconds_since_init() + 1;
        else vk.recreate = true;
    }
    if vk.vsync && vk.present_wait && vk.present_wait_paused_until > 0 {
        platform_sleep_until(vk.last_wait + 1.0 / max(platform.refresh_hz, 24));
        vk.last_wait = seconds_since_init();
    }
    // Without present_wait: the GPU has finished the frame before the last.
    previous := *vk.frames[(vk.frame_index + FRAMES - 1) % FRAMES];
    if previous.submitted vk_call.WaitForFences(vk.device, 1, *previous.fence, VK_TRUE, FENCE_TIMEOUT);
}

renderer_render :: (clear: Color) {
    renderer_stats = .{};
    vk.acquired = false;
    if !vk.device return;

    if renderer_settings.vsync != vk.vsync || vk.recreate || platform.width != vk.asked_width || platform.height != vk.asked_height {
        if !create_swapchain() return;
    }
    if !vk.swapchain || vk.width <= 0 || vk.height <= 0 return;   // Minimized: nothing to draw into.

    // This frame's slot. The GPU finished with it two frames ago; check anyway.
    vk.frame_index = (vk.frame_index + 1) % FRAMES;
    frame := *vk.frames[vk.frame_index];
    if frame.submitted {
        vk_call.WaitForFences(vk.device, 1, *frame.fence, VK_TRUE, FENCE_TIMEOUT);
        frame.submitted = false;
    }
    for * frame.garbage destroy_atlas_image(it);   // Atlas images no frame in flight can still use.
    frame.garbage.count = 0;

    result := vk_call.AcquireNextImageKHR(vk.device, vk.swapchain, ACQUIRE_TIMEOUT, frame.acquired, null, *vk.image_index);
    if result == .ERROR_OUT_OF_DATE_KHR {
        if !create_swapchain() return;
        result = vk_call.AcquireNextImageKHR(vk.device, vk.swapchain, ACQUIRE_TIMEOUT, frame.acquired, null, *vk.image_index);
    }
    if result == .SUBOPTIMAL_KHR vk.recreate = true;   // Draw this one; a new swapchain next frame.
    else if result != .SUCCESS {
        if result == .ERROR_DEVICE_LOST device_lost();
        return;   // Skipped (timed out): nothing to present.
    }
    vk.acquired = true;
    vk.committed = false;

    commands := frame.commands;
    vk_call.ResetCommandBuffer(commands, 0);
    begin := VkCommandBufferBeginInfo.{flags = .ONE_TIME_SUBMIT_BIT};
    vk_call.BeginCommandBuffer(commands, *begin);

    upload_atlas(commands, frame, *vk.glyph_atlas, *glyph_atlas, .R8_UNORM);
    upload_atlas(commands, frame, *vk.color_atlas, *color_atlas, .R8G8B8A8_UNORM);
    bind_atlases(frame);
    count := upload_instances(frame);

    clear_value: VkClearValue;
    for 0..3 clear_value.color._float32[it] = ((clear >> (it * 8)) & 0xFF) / 255.0;
    pass := VkRenderPassBeginInfo.{
        renderPass      = vk.render_pass,
        framebuffer     = vk.framebuffers[vk.image_index],
        renderArea      = .{extent = .{xx vk.width, xx vk.height}},
        clearValueCount = 1,
        pClearValues    = *clear_value,
    };
    vk_call.CmdBeginRenderPass(commands, *pass, .INLINE);
    if count > 0 {
        viewport := VkViewport.{width = xx vk.width, height = xx vk.height, maxDepth = 1};
        scissor  := VkRect2D.{extent = .{xx vk.width, xx vk.height}};
        constants: Frame_Constants;
        constants.viewport_size  = .[cast(float) vk.width, cast(float) vk.height];
        constants.atlas_inv_size = .[1.0 / max(glyph_atlas.size, 1), 1.0 / max(glyph_atlas.size, 1)];
        constants.color_atlas_inv_size = .[1.0 / max(color_atlas.size, 1), 1.0 / max(color_atlas.size, 1)];
        offset: VkDeviceSize = 0;
        vk_call.CmdBindPipeline(commands, .GRAPHICS, vk.pipeline);
        vk_call.CmdSetViewport(commands, 0, 1, *viewport);
        vk_call.CmdSetScissor(commands, 0, 1, *scissor);
        vk_call.CmdPushConstants(commands, vk.pipeline_layout, .VERTEX_BIT, 0, size_of(Frame_Constants), *constants);
        vk_call.CmdBindDescriptorSets(commands, .GRAPHICS, vk.pipeline_layout, 0, 1, *frame.descriptor, 0, null);
        vk_call.CmdBindVertexBuffers(commands, 0, 1, *frame.instances.buffer, *offset);
        vk_call.CmdDraw(commands, 4, xx count, 0, 0);
        renderer_stats.instances  = count;
        renderer_stats.draw_calls = 1;
    }
    vk_call.CmdEndRenderPass(commands);
    // Ended and submitted in renderer_present, unless a capture does it first.
}

renderer_present :: () {
    vk.waited = false;
    if !vk.acquired return;
    vk.acquired = false;
    frame := *vk.frames[vk.frame_index];
    if !vk.committed && !submit(frame) return;

    present_id := vk.submitted + 1;
    ids := VkPresentIdKHR.{swapchainCount = 1, pPresentIds = *present_id};
    present := VkPresentInfoKHR.{
        waitSemaphoreCount = 1,
        pWaitSemaphores    = *vk.rendered[vk.image_index],
        swapchainCount     = 1,
        pSwapchains        = *vk.swapchain,
        pImageIndices      = *vk.image_index,
    };
    if vk.present_wait present.pNext = *ids;
    result := vk_call.QueuePresentKHR(vk.queue, *present);
    vk.submitted = present_id;   // Even when it failed: ids only ever increase.
    if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR vk.recreate = true;
    else if result == .ERROR_DEVICE_LOST device_lost();
}

renderer_tearing_supported :: () -> bool { return vk.immediate_supported; }

// Reads back the frame just rendered (call between renderer_render and
// renderer_present) and writes it as a PNG. For screenshots and tests.
renderer_capture_png :: (path: string) -> bool {
    if !vk.acquired || vk.committed || !vk.capture_supported return false;
    frame := *vk.frames[vk.frame_index];
    w, h := vk.width, vk.height;
    bytes := w * h * 4;
    if vk.capture.size < bytes {
        destroy_buffer(*vk.capture);
        if !create_buffer(*vk.capture, bytes, .TRANSFER_DST_BIT, .HOST_VISIBLE_BIT | .HOST_COHERENT_BIT) return false;
    }

    image := vk.images[vk.image_index];
    commands := frame.commands;
    to_transfer := image_barrier(image, .PRESENT_SRC_KHR, .TRANSFER_SRC_OPTIMAL, .COLOR_ATTACHMENT_WRITE_BIT, .TRANSFER_READ_BIT);
    vk_call.CmdPipelineBarrier(commands, .COLOR_ATTACHMENT_OUTPUT_BIT, .TRANSFER_BIT, 0, 0, null, 0, null, 1, *to_transfer);
    region := VkBufferImageCopy.{
        imageSubresource = .{aspectMask = .COLOR_BIT, layerCount = 1},
        imageExtent      = .{xx w, xx h, 1},
    };
    vk_call.CmdCopyImageToBuffer(commands, image, .TRANSFER_SRC_OPTIMAL, vk.capture.buffer, 1, *region);
    back := image_barrier(image, .TRANSFER_SRC_OPTIMAL, .PRESENT_SRC_KHR, .TRANSFER_READ_BIT, 0);
    vk_call.CmdPipelineBarrier(commands, .TRANSFER_BIT, .BOTTOM_OF_PIPE_BIT, 0, 0, null, 0, null, 1, *back);
    if !submit(frame) return false;
    vk_call.WaitForFences(vk.device, 1, *frame.fence, VK_TRUE, FENCE_TIMEOUT);

    src := cast(*u8) vk.capture.mapped;
    rgb := NewArray(w * h * 3, u8,, temp);
    bgra := vk.format == .B8G8R8A8_UNORM;
    for i: 0..w * h - 1 {
        s := src + i * 4;
        d := rgb.data + i * 3;
        d[0] = ifx bgra then s[2] else s[0];
        d[1] = s[1];
        d[2] = ifx bgra then s[0] else s[2];
    }
    return write_png_rgb(path, w, h, rgb.data);
}

#scope_file

#import "Vulkan";
POSIX :: #import "POSIX";

FRAMES :: 3;
FENCE_TIMEOUT        :: 1_000_000_000;   // Nanoseconds. A frame that takes a second is a hung GPU.
ACQUIRE_TIMEOUT      :: 1_000_000_000;
PRESENT_WAIT_TIMEOUT :: 100_000_000;     // Longer than any refresh.

Buffer :: struct {
    buffer: VkBuffer;
    memory: VkDeviceMemory;
    mapped: *void;
    size:   int;
}

Atlas_Image :: struct {
    image:  VkImage;
    memory: VkDeviceMemory;
    view:   VkImageView;
    generation: u32;
    size:   s32;
    ready:  bool;   // Has a layout: written at least once.
}

Frame_Slot :: struct {
    commands:   VkCommandBuffer;
    fence:      VkFence;
    acquired:   VkSemaphore;     // Signalled when the swapchain image is ours.
    submitted:  bool;            // The fence will signal.
    instances:  Buffer;
    staging:    Buffer;          // Atlas rows on their way to the GPU.
    descriptor: VkDescriptorSet;
    bound_glyph, bound_color: VkImageView;   // What `descriptor` points at.
    garbage:    [..] Atlas_Image;   // Replaced atlases, destroyed when this slot comes round again.
}

Vulkan_State :: struct {
    instance:  VkInstance;
    surface:   VkSurfaceKHR;
    physical:  VkPhysicalDevice;
    device:    VkDevice;
    queue:     VkQueue;
    queue_family: u32;
    device_name: string;
    memory: VkPhysicalDeviceMemoryProperties;
    present_wait: bool;          // VK_KHR_present_id and VK_KHR_present_wait.
    present_wait_paused_until: float64;
    last_wait: float64;          // When renderer_wait_for_frame last returned while paused.
    immediate_supported, mailbox_supported: bool;
    capture_supported: bool;

    swapchain: VkSwapchainKHR;
    format:    VkFormat;
    width, height: s32;          // Of the swapchain's images.
    asked_width, asked_height: s32;   // The window's size when it was made.
    vsync:     bool;
    recreate:  bool;             // Out of date or suboptimal: make a new one.
    images:       [..] VkImage;
    views:        [..] VkImageView;
    framebuffers: [..] VkFramebuffer;
    rendered:     [..] VkSemaphore;   // Per image: the frame drawn into it is done.
    swapchain_first_id: u64;     // Present ids of this swapchain start here.

    render_pass:     VkRenderPass;
    set_layout:      VkDescriptorSetLayout;
    pipeline_layout: VkPipelineLayout;
    pipeline:        VkPipeline;
    sampler:         VkSampler;
    descriptor_pool: VkDescriptorPool;
    command_pool:    VkCommandPool;

    frames: [FRAMES] Frame_Slot;
    frame_index: int;
    glyph_atlas: Atlas_Image;
    color_atlas: Atlas_Image;    // Color emoji; a 1x1 placeholder while there are none.
    capture: Buffer;

    waited:    bool;   // Waited, not presented since.
    acquired:  bool;   // This frame has a swapchain image.
    committed: bool;   // This frame's commands are submitted (a capture did it).
    image_index: u32;
    submitted: u64;    // Frames presented so far: the last present id.
}

vk: Vulkan_State;

Frame_Constants :: struct {
    viewport_size:  [2] float;
    atlas_inv_size: [2] float;
    color_atlas_inv_size: [2] float;
}

// Vulkan's procedures, loaded through vkGetInstanceProcAddr ("vk" + name).
Vk_Global :: struct {
    CreateInstance:                       PFN_vkCreateInstance;
    EnumerateInstanceExtensionProperties: PFN_vkEnumerateInstanceExtensionProperties;
    EnumerateInstanceLayerProperties:     PFN_vkEnumerateInstanceLayerProperties;
    EnumerateInstanceVersion:             PFN_vkEnumerateInstanceVersion; @optional
}

Vk_Instance :: struct {
    DestroyInstance:                          PFN_vkDestroyInstance;
    EnumeratePhysicalDevices:                 PFN_vkEnumeratePhysicalDevices;
    GetPhysicalDeviceProperties:              PFN_vkGetPhysicalDeviceProperties;
    GetPhysicalDeviceFeatures2:               PFN_vkGetPhysicalDeviceFeatures2; @optional
    GetPhysicalDeviceQueueFamilyProperties:   PFN_vkGetPhysicalDeviceQueueFamilyProperties;
    GetPhysicalDeviceMemoryProperties:        PFN_vkGetPhysicalDeviceMemoryProperties;
    EnumerateDeviceExtensionProperties:       PFN_vkEnumerateDeviceExtensionProperties;
    CreateDevice:                             PFN_vkCreateDevice;
    CreateXlibSurfaceKHR:                     PFN_vkCreateXlibSurfaceKHR; @optional
    CreateWaylandSurfaceKHR:                  PFN_vkCreateWaylandSurfaceKHR; @optional
    DestroySurfaceKHR:                        PFN_vkDestroySurfaceKHR;
    GetPhysicalDeviceSurfaceSupportKHR:       PFN_vkGetPhysicalDeviceSurfaceSupportKHR;
    GetPhysicalDeviceSurfaceCapabilitiesKHR:  PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR;
    GetPhysicalDeviceSurfaceFormatsKHR:       PFN_vkGetPhysicalDeviceSurfaceFormatsKHR;
    GetPhysicalDeviceSurfacePresentModesKHR:  PFN_vkGetPhysicalDeviceSurfacePresentModesKHR;

    DestroyDevice:              PFN_vkDestroyDevice;
    DeviceWaitIdle:             PFN_vkDeviceWaitIdle;
    GetDeviceQueue:             PFN_vkGetDeviceQueue;
    CreateSwapchainKHR:         PFN_vkCreateSwapchainKHR;
    DestroySwapchainKHR:        PFN_vkDestroySwapchainKHR;
    GetSwapchainImagesKHR:      PFN_vkGetSwapchainImagesKHR;
    AcquireNextImageKHR:        PFN_vkAcquireNextImageKHR;
    QueuePresentKHR:            PFN_vkQueuePresentKHR;
    WaitForPresentKHR:          PFN_vkWaitForPresentKHR; @optional
    QueueSubmit:                PFN_vkQueueSubmit;
    CreateImageView:            PFN_vkCreateImageView;
    DestroyImageView:           PFN_vkDestroyImageView;
    CreateImage:                PFN_vkCreateImage;
    DestroyImage:               PFN_vkDestroyImage;
    GetImageMemoryRequirements: PFN_vkGetImageMemoryRequirements;
    BindImageMemory:            PFN_vkBindImageMemory;
    CreateBuffer:               PFN_vkCreateBuffer;
    DestroyBuffer:              PFN_vkDestroyBuffer;
    GetBufferMemoryRequirements: PFN_vkGetBufferMemoryRequirements;
    BindBufferMemory:           PFN_vkBindBufferMemory;
    AllocateMemory:             PFN_vkAllocateMemory;
    FreeMemory:                 PFN_vkFreeMemory;
    MapMemory:                  PFN_vkMapMemory;
    CreateFramebuffer:          PFN_vkCreateFramebuffer;
    DestroyFramebuffer:         PFN_vkDestroyFramebuffer;
    CreateRenderPass:           PFN_vkCreateRenderPass;
    DestroyRenderPass:          PFN_vkDestroyRenderPass;
    CreateShaderModule:         PFN_vkCreateShaderModule;
    DestroyShaderModule:        PFN_vkDestroyShaderModule;
    CreateDescriptorSetLayout:  PFN_vkCreateDescriptorSetLayout;
    DestroyDescriptorSetLayout: PFN_vkDestroyDescriptorSetLayout;
    CreatePipelineLayout:       PFN_vkCreatePipelineLayout;
    DestroyPipelineLayout:      PFN_vkDestroyPipelineLayout;
    CreateGraphicsPipelines:    PFN_vkCreateGraphicsPipelines;
    DestroyPipeline:            PFN_vkDestroyPipeline;
    CreateSampler:              PFN_vkCreateSampler;
    DestroySampler:             PFN_vkDestroySampler;
    CreateDescriptorPool:       PFN_vkCreateDescriptorPool;
    DestroyDescriptorPool:      PFN_vkDestroyDescriptorPool;
    AllocateDescriptorSets:     PFN_vkAllocateDescriptorSets;
    UpdateDescriptorSets:       PFN_vkUpdateDescriptorSets;
    CreateCommandPool:          PFN_vkCreateCommandPool;
    DestroyCommandPool:         PFN_vkDestroyCommandPool;
    AllocateCommandBuffers:     PFN_vkAllocateCommandBuffers;
    ResetCommandBuffer:         PFN_vkResetCommandBuffer;
    BeginCommandBuffer:         PFN_vkBeginCommandBuffer;
    EndCommandBuffer:           PFN_vkEndCommandBuffer;
    CreateFence:                PFN_vkCreateFence;
    DestroyFence:               PFN_vkDestroyFence;
    WaitForFences:              PFN_vkWaitForFences;
    ResetFences:                PFN_vkResetFences;
    CreateSemaphore:            PFN_vkCreateSemaphore;
    DestroySemaphore:           PFN_vkDestroySemaphore;

    CmdBeginRenderPass:     PFN_vkCmdBeginRenderPass;
    CmdEndRenderPass:       PFN_vkCmdEndRenderPass;
    CmdBindPipeline:        PFN_vkCmdBindPipeline;
    CmdSetViewport:         PFN_vkCmdSetViewport;
    CmdSetScissor:          PFN_vkCmdSetScissor;
    CmdPushConstants:       PFN_vkCmdPushConstants;
    CmdBindDescriptorSets:  PFN_vkCmdBindDescriptorSets;
    CmdBindVertexBuffers:   PFN_vkCmdBindVertexBuffers;
    CmdDraw:                PFN_vkCmdDraw;
    CmdPipelineBarrier:     PFN_vkCmdPipelineBarrier;
    CmdCopyBufferToImage:   PFN_vkCmdCopyBufferToImage;
    CmdCopyImageToBuffer:   PFN_vkCmdCopyImageToBuffer;
}

GetInstanceProcAddr: PFN_vkGetInstanceProcAddr;
vk_global: Vk_Global;
vk_call: Vk_Instance;
libvulkan_handle: *void;

load_vulkan :: () -> bool {
    if !libvulkan_handle {
        libvulkan_handle = POSIX.dlopen("libvulkan.so.1", POSIX.RTLD_NOW | POSIX.RTLD_LOCAL);
        if !libvulkan_handle return fail("Loading libvulkan.so.1 (is a Vulkan driver installed? Mesa's is mesa-vulkan-drivers)");
        GetInstanceProcAddr = cast(PFN_vkGetInstanceProcAddr) POSIX.dlsym(libvulkan_handle, "vkGetInstanceProcAddr");
        if !GetInstanceProcAddr return fail("vkGetInstanceProcAddr");
    }
    if !dl_fill(*vk_global, "vk", lookup_instance_proc, null) return fail("Loading Vulkan");
    return true;
}

lookup_instance_proc :: (name: *u8, instance: *void) -> *void {
    return cast(*void) GetInstanceProcAddr(cast(VkInstance) instance, name);
}

create_instance :: () -> bool {
    api_version := VK_API_VERSION_1_0;
    if vk_global.EnumerateInstanceVersion {
        version: u32;
        if vk_global.EnumerateInstanceVersion(*version) == .SUCCESS && version >= VK_API_VERSION_1_1 api_version = VK_API_VERSION_1_1;
    }

    // The window system's surface: Wayland's or X11's (platform_linux).
    window_system := ifx platform_wayland_surface then "VK_KHR_wayland_surface" else "VK_KHR_xlib_surface";
    extensions := *u8.["VK_KHR_surface".data, window_system.data];
    layers: [..] *u8;
    layers.allocator = temp;
    #if !APP_RELEASE {
        // Debug builds check themselves when the validation layer is installed
        // (vulkan-validationlayers); it reports to stdout.
        count: u32;
        vk_global.EnumerateInstanceLayerProperties(*count, null);
        available := NewArray(count, VkLayerProperties,, temp);
        vk_global.EnumerateInstanceLayerProperties(*count, available.data);
        for * available if to_string(it.layerName.data) == "VK_LAYER_KHRONOS_validation" array_add(*layers, "VK_LAYER_KHRONOS_validation".data);
    }

    app := VkApplicationInfo.{
        pApplicationName   = "Uppies",
        applicationVersion = VK_MAKE_VERSION(1, 0, 0),
        pEngineName        = "Uppies",
        apiVersion         = api_version,
    };
    info := VkInstanceCreateInfo.{
        pApplicationInfo        = *app,
        enabledLayerCount       = xx layers.count,
        ppEnabledLayerNames     = layers.data,
        enabledExtensionCount   = extensions.count,
        ppEnabledExtensionNames = extensions.data,
    };
    if vk_global.CreateInstance(*info, null, *vk.instance) != .SUCCESS return fail("vkCreateInstance");
    if layers.count log("Vulkan validation layer enabled.\n");
    if !dl_fill(*vk_call, "vk", lookup_instance_proc, vk.instance) return fail("Loading Vulkan's instance procedures");
    if api_version < VK_API_VERSION_1_1 vk_call.GetPhysicalDeviceFeatures2 = null;
    return true;
}

create_surface :: () -> bool {
    if platform_wayland_surface {
        if !vk_call.CreateWaylandSurfaceKHR return fail("Loading vkCreateWaylandSurfaceKHR");
        info := VkWaylandSurfaceCreateInfoKHR.{display = platform_wayland_display, surface = platform_wayland_surface};
        if vk_call.CreateWaylandSurfaceKHR(vk.instance, *info, null, *vk.surface) != .SUCCESS return fail("vkCreateWaylandSurfaceKHR");
        return true;
    }
    if !platform_x11_vk_display || !platform_x11_window return fail("No X11 window");
    if !vk_call.CreateXlibSurfaceKHR return fail("Loading vkCreateXlibSurfaceKHR");
    info := VkXlibSurfaceCreateInfoKHR.{dpy = platform_x11_vk_display, window = platform_x11_window};
    if vk_call.CreateXlibSurfaceKHR(vk.instance, *info, null, *vk.surface) != .SUCCESS return fail("vkCreateXlibSurfaceKHR");
    return true;
}

// A device that can draw and present to the window. The integrated GPU by
// default, as on the other platforms: it is the one already awake, and
// frames needn't cross to it from a discrete one. DRI_PRIME or
// MESA_VK_DEVICE_SELECT choose instead (the loader lists their pick first),
// and UPPIES_GPU picks by name.
pick_device :: () -> bool {
    count: u32;
    vk_call.EnumeratePhysicalDevices(vk.instance, *count, null);
    devices := NewArray(count, VkPhysicalDevice,, temp);
    vk_call.EnumeratePhysicalDevices(vk.instance, *count, devices.data);

    wanted := to_string(POSIX.getenv("UPPIES_GPU"));
    loader_order := POSIX.getenv("DRI_PRIME") != null || POSIX.getenv("MESA_VK_DEVICE_SELECT") != null;
    PREFERENCE :: VkPhysicalDeviceType.[.INTEGRATED_GPU, .DISCRETE_GPU, .VIRTUAL_GPU, .OTHER, .CPU];

    best_rank := PREFERENCE.count;
    for device: devices {
        properties: VkPhysicalDeviceProperties;
        vk_call.GetPhysicalDeviceProperties(device, *properties);
        family, ok := usable_queue_family(device);
        if !ok continue;
        name := to_string(properties.deviceName.data);
        rank := PREFERENCE.count - 1;
        for PREFERENCE if it == properties.deviceType rank = it_index;
        if loader_order rank = 0;
        if wanted && contains(to_lower_copy(name,, temp), to_lower_copy(wanted,, temp)) rank = -1;
        if rank < best_rank {
            best_rank = rank;
            vk.physical = device;
            vk.queue_family = family;
            vk.device_name = copy_string(name);
            if properties.deviceType == .CPU log("Only a software Vulkan device (%) is available: drawing will be slow.\n", name);
        }
        if loader_order break;
    }
    if !vk.physical return fail("Finding a Vulkan device that can draw to the window");
    vk_call.GetPhysicalDeviceMemoryProperties(vk.physical, *vk.memory);
    return true;
}

usable_queue_family :: (device: VkPhysicalDevice) -> u32, bool {
    if !has_device_extension(device, "VK_KHR_swapchain") return 0, false;
    count: u32;
    vk_call.GetPhysicalDeviceQueueFamilyProperties(device, *count, null);
    families := NewArray(count, VkQueueFamilyProperties,, temp);
    vk_call.GetPhysicalDeviceQueueFamilyProperties(device, *count, families.data);
    for families {
        if !(it.queueFlags & .GRAPHICS_BIT) continue;
        present: VkBool32;
        vk_call.GetPhysicalDeviceSurfaceSupportKHR(device, xx it_index, vk.surface, *present);
        if !present continue;
        // And it can say what the window takes: a GPU that can't share its
        // buffers with this compositor (one without dmabuf) answers yes
        // above, then fails here.
        capabilities: VkSurfaceCapabilitiesKHR;
        format_count: u32;
        if vk_call.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, vk.surface, *capabilities) != .SUCCESS return 0, false;
        if vk_call.GetPhysicalDeviceSurfaceFormatsKHR(device, vk.surface, *format_count, null) != .SUCCESS || !format_count return 0, false;
        return xx it_index, true;
    }
    return 0, false;
}

has_device_extension :: (device: VkPhysicalDevice, name: string) -> bool {
    count: u32;
    vk_call.EnumerateDeviceExtensionProperties(device, null, *count, null);
    extensions := NewArray(count, VkExtensionProperties,, temp);
    vk_call.EnumerateDeviceExtensionProperties(device, null, *count, extensions.data);
    for * extensions if to_string(it.extensionName.data) == name return true;
    return false;
}

create_device :: () -> bool {
    extensions: [..] *u8;
    extensions.allocator = temp;
    array_add(*extensions, "VK_KHR_swapchain".data);

    // Present wait: the frame latency waitable's counterpart.
    present_id   := VkPhysicalDevicePresentIdFeaturesKHR.{};
    present_wait := VkPhysicalDevicePresentWaitFeaturesKHR.{};
    if vk_call.GetPhysicalDeviceFeatures2 && vk_call.WaitForPresentKHR
       && has_device_extension(vk.physical, "VK_KHR_present_id") && has_device_extension(vk.physical, "VK_KHR_present_wait") {
        present_id.pNext = *present_wait;
        features := VkPhysicalDeviceFeatures2.{pNext = *present_id};
        vk_call.GetPhysicalDeviceFeatures2(vk.physical, *features);
        vk.present_wait = present_id.presentId && present_wait.presentWait;
    }
    if vk.present_wait array_add(*extensions, "VK_KHR_present_id".data, "VK_KHR_present_wait".data);
    else present_id.presentId, present_wait.presentWait = VK_FALSE, VK_FALSE;

    priority: float = 1;
    queue := VkDeviceQueueCreateInfo.{queueFamilyIndex = vk.queue_family, queueCount = 1, pQueuePriorities = *priority};
    info := VkDeviceCreateInfo.{
        queueCreateInfoCount    = 1,
        pQueueCreateInfos       = *queue,
        enabledExtensionCount   = xx extensions.count,
        ppEnabledExtensionNames = extensions.data,
    };
    if vk.present_wait info.pNext = *present_id;
    if vk_call.CreateDevice(vk.physical, *info, null, *vk.device) != .SUCCESS return fail("vkCreateDevice");
    vk_call.GetDeviceQueue(vk.device, vk.queue_family, 0, *vk.queue);
    if !vk.present_wait vk_call.WaitForPresentKHR = null;

    pool := VkCommandPoolCreateInfo.{flags = .RESET_COMMAND_BUFFER_BIT, queueFamilyIndex = vk.queue_family};
    if vk_call.CreateCommandPool(vk.device, *pool, null, *vk.command_pool) != .SUCCESS return fail("vkCreateCommandPool");
    return true;
}

// The swapchain's format: BGRA8 or RGBA8, UNORM (not _SRGB): colors are
// blended in sRGB, as on the other backends.
choose_format :: () -> VkFormat, VkColorSpaceKHR {
    count: u32;
    vk_call.GetPhysicalDeviceSurfaceFormatsKHR(vk.physical, vk.surface, *count, null);
    formats := NewArray(count, VkSurfaceFormatKHR,, temp);
    vk_call.GetPhysicalDeviceSurfaceFormatsKHR(vk.physical, vk.surface, *count, formats.data);
    for wanted: VkFormat.[.B8G8R8A8_UNORM, .R8G8B8A8_UNORM] {
        for formats if it.format == wanted && it.colorSpace == .COLOR_SPACE_SRGB_NONLINEAR_KHR return it.format, it.colorSpace;
    }
    if count && formats[0].format != .UNDEFINED return formats[0].format, formats[0].colorSpace;
    return .B8G8R8A8_UNORM, .COLOR_SPACE_SRGB_NONLINEAR_KHR;
}

// Made, or made again for a new size, vsync setting, or after it went out
// of date.
create_swapchain :: () -> bool {
    vk.recreate = false;
    vk.vsync = renderer_settings.vsync;
    vk.width, vk.height = platform.width, platform.height;
    vk.asked_width, vk.asked_height = platform.width, platform.height;

    capabilities: VkSurfaceCapabilitiesKHR;
    if vk_call.GetPhysicalDeviceSurfaceCapabilitiesKHR(vk.physical, vk.surface, *capabilities) != .SUCCESS {
        vk.width, vk.height = 0, 0;
        return fail("vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
    }
    if capabilities.currentExtent.width != 0xFFFF_FFFF {
        vk.width, vk.height = xx capabilities.currentExtent.width, xx capabilities.currentExtent.height;
    }
    if vk.width <= 0 || vk.height <= 0 return true;   // Minimized: make it when there is something to show.

    count: u32;
    vk_call.GetPhysicalDeviceSurfacePresentModesKHR(vk.physical, vk.surface, *count, null);
    modes := NewArray(count, VkPresentModeKHR,, temp);
    vk_call.GetPhysicalDeviceSurfacePresentModesKHR(vk.physical, vk.surface, *count, modes.data);
    vk.immediate_supported = array_find(modes, .IMMEDIATE_KHR);
    vk.mailbox_supported   = array_find(modes, .MAILBOX_KHR);
    mode := VkPresentModeKHR.FIFO_KHR;
    if !vk.vsync {
        if vk.immediate_supported    mode = .IMMEDIATE_KHR;
        else if vk.mailbox_supported mode = .MAILBOX_KHR;
    } else if platform_wayland_surface && vk.present_wait && vk.mailbox_supported {
        // Wayland's FIFO waits inside vkQueuePresentKHR, without a timeout, for
        // the compositor's frame callback, which never comes while the window
        // isn't shown (another workspace, a compositor's own idea): the app
        // would hang. MAILBOX never waits there, and the pacing is the same:
        // renderer_wait_for_frame waits for the frame before the last.
        mode = .MAILBOX_KHR;
    }

    images := max(cast(u32) 3, capabilities.minImageCount);
    if capabilities.maxImageCount images = min(images, capabilities.maxImageCount);
    usage := VkImageUsageFlags.COLOR_ATTACHMENT_BIT;
    vk.capture_supported = scripted() && (capabilities.supportedUsageFlags & .TRANSFER_SRC_BIT) != 0;
    if vk.capture_supported usage |= .TRANSFER_SRC_BIT;   // Read back for screenshots.
    alpha := VkCompositeAlphaFlagBitsKHR.OPAQUE_BIT_KHR;
    if !(capabilities.supportedCompositeAlpha & .OPAQUE_BIT_KHR) alpha = .INHERIT_BIT_KHR;

    format, color_space := choose_format();
    if vk.render_pass && format != vk.format return fail("The window's pixel format changed");
    vk.format = format;

    old := vk.swapchain;
    info := VkSwapchainCreateInfoKHR.{
        surface          = vk.surface,
        minImageCount    = images,
        imageFormat      = format,
        imageColorSpace  = color_space,
        imageExtent      = .{xx vk.width, xx vk.height},
        imageArrayLayers = 1,
        imageUsage       = usage,
        imageSharingMode = .EXCLUSIVE,
        preTransform     = capabilities.currentTransform,
        compositeAlpha   = alpha,
        presentMode      = mode,
        clipped          = VK_TRUE,
        oldSwapchain     = old,
    };
    // Nothing may still use the old swapchain's images or semaphores.
    vk_call.DeviceWaitIdle(vk.device);
    for * vk.frames it.submitted = false;
    destroy_swapchain_parts();
    result := vk_call.CreateSwapchainKHR(vk.device, *info, null, *vk.swapchain);
    if old vk_call.DestroySwapchainKHR(vk.device, old, null);
    if result != .SUCCESS {
        vk.swapchain = null;
        if result == .ERROR_DEVICE_LOST device_lost();
        return fail("vkCreateSwapchainKHR");
    }
    vk.swapchain_first_id = vk.submitted + 1;
    vk.present_wait_paused_until = 0;

    if !vk.render_pass && !create_render_pass() return false;

    vk_call.GetSwapchainImagesKHR(vk.device, vk.swapchain, *count, null);
    array_resize(*vk.images, count);
    vk_call.GetSwapchainImagesKHR(vk.device, vk.swapchain, *count, vk.images.data);
    array_resize(*vk.views, count);
    array_resize(*vk.framebuffers, count);
    array_resize(*vk.rendered, count);
    for image, i: vk.images {
        view_info := VkImageViewCreateInfo.{
            image = image, viewType = ._2D, format = format,
            subresourceRange = .{aspectMask = .COLOR_BIT, levelCount = 1, layerCount = 1},
        };
        if vk_call.CreateImageView(vk.device, *view_info, null, *vk.views[i]) != .SUCCESS return fail("vkCreateImageView");
        framebuffer_info := VkFramebufferCreateInfo.{
            renderPass = vk.render_pass, attachmentCount = 1, pAttachments = *vk.views[i],
            width = xx vk.width, height = xx vk.height, layers = 1,
        };
        if vk_call.CreateFramebuffer(vk.device, *framebuffer_info, null, *vk.framebuffers[i]) != .SUCCESS return fail("vkCreateFramebuffer");
        semaphore_info: VkSemaphoreCreateInfo;
        if vk_call.CreateSemaphore(vk.device, *semaphore_info, null, *vk.rendered[i]) != .SUCCESS return fail("vkCreateSemaphore");
    }
    return true;
}

destroy_swapchain_parts :: () {
    for vk.framebuffers if it vk_call.DestroyFramebuffer(vk.device, it, null);
    for vk.views        if it vk_call.DestroyImageView(vk.device, it, null);
    for vk.rendered     if it vk_call.DestroySemaphore(vk.device, it, null);
    vk.framebuffers.count, vk.views.count, vk.rendered.count, vk.images.count = 0, 0, 0, 0;
}

create_render_pass :: () -> bool {
    attachment := VkAttachmentDescription.{
        format         = vk.format,
        samples        = ._1_BIT,
        loadOp         = .CLEAR,
        storeOp        = .STORE,
        stencilLoadOp  = .DONT_CARE,
        stencilStoreOp = .DONT_CARE,
        initialLayout  = .UNDEFINED,
        finalLayout    = .PRESENT_SRC_KHR,
    };
    reference := VkAttachmentReference.{attachment = 0, layout = .COLOR_ATTACHMENT_OPTIMAL};
    subpass := VkSubpassDescription.{pipelineBindPoint = .GRAPHICS, colorAttachmentCount = 1, pColorAttachments = *reference};
    // The image's layout changes once the acquire semaphore has been waited
    // on, which happens at this stage.
    dependency := VkSubpassDependency.{
        srcSubpass    = VK_SUBPASS_EXTERNAL,
        dstSubpass    = 0,
        srcStageMask  = .COLOR_ATTACHMENT_OUTPUT_BIT,
        dstStageMask  = .COLOR_ATTACHMENT_OUTPUT_BIT,
        dstAccessMask = .COLOR_ATTACHMENT_WRITE_BIT,
    };
    info := VkRenderPassCreateInfo.{
        attachmentCount = 1, pAttachments  = *attachment,
        subpassCount    = 1, pSubpasses    = *subpass,
        dependencyCount = 1, pDependencies = *dependency,
    };
    if vk_call.CreateRenderPass(vk.device, *info, null, *vk.render_pass) != .SUCCESS return fail("vkCreateRenderPass");
    return create_graphics_pipeline();
}

create_pipeline :: () -> bool {
    sampler_info := VkSamplerCreateInfo.{
        magFilter = .LINEAR, minFilter = .LINEAR, mipmapMode = .NEAREST,
        addressModeU = .CLAMP_TO_EDGE, addressModeV = .CLAMP_TO_EDGE, addressModeW = .CLAMP_TO_EDGE,
        maxLod = 0,
    };
    if vk_call.CreateSampler(vk.device, *sampler_info, null, *vk.sampler) != .SUCCESS return fail("vkCreateSampler");

    bindings := VkDescriptorSetLayoutBinding.[
        .{binding = 0, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = .FRAGMENT_BIT},
        .{binding = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = .FRAGMENT_BIT},
    ];
    for * bindings it.pImmutableSamplers = *vk.sampler;
    set_info := VkDescriptorSetLayoutCreateInfo.{bindingCount = bindings.count, pBindings = bindings.data};
    if vk_call.CreateDescriptorSetLayout(vk.device, *set_info, null, *vk.set_layout) != .SUCCESS return fail("vkCreateDescriptorSetLayout");

    push := VkPushConstantRange.{stageFlags = .VERTEX_BIT, size = size_of(Frame_Constants)};
    layout_info := VkPipelineLayoutCreateInfo.{setLayoutCount = 1, pSetLayouts = *vk.set_layout, pushConstantRangeCount = 1, pPushConstantRanges = *push};
    if vk_call.CreatePipelineLayout(vk.device, *layout_info, null, *vk.pipeline_layout) != .SUCCESS return fail("vkCreatePipelineLayout");

    pool_size := VkDescriptorPoolSize.{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = FRAMES * 2};
    pool_info := VkDescriptorPoolCreateInfo.{maxSets = FRAMES, poolSizeCount = 1, pPoolSizes = *pool_size};
    if vk_call.CreateDescriptorPool(vk.device, *pool_info, null, *vk.descriptor_pool) != .SUCCESS return fail("vkCreateDescriptorPool");
    return true;
}

create_graphics_pipeline :: () -> bool {
    vert := create_shader_module(shader_ui_vert);
    frag := create_shader_module(shader_ui_frag);
    defer { vk_call.DestroyShaderModule(vk.device, vert, null); vk_call.DestroyShaderModule(vk.device, frag, null); }
    if !vert || !frag return fail("vkCreateShaderModule");
    stages := VkPipelineShaderStageCreateInfo.[
        .{stage = .VERTEX_BIT,   module = vert, pName = "main"},
        .{stage = .FRAGMENT_BIT, module = frag, pName = "main"},
    ];

    // One instance per primitive, stepped per instance: the attributes are
    // Draw_Instance's members (locations as in ui.glsl).
    binding := VkVertexInputBindingDescription.{binding = 0, stride = size_of(Draw_Instance), inputRate = .INSTANCE};
    attributes := VkVertexInputAttributeDescription.[
        .{location = 0, format = .R32G32B32A32_SFLOAT, offset = #run member_offset(Draw_Instance, "rect")},
        .{location = 1, format = .R32G32B32A32_SFLOAT, offset = #run member_offset(Draw_Instance, "uv")},
        .{location = 2, format = .R32G32B32A32_SFLOAT, offset = #run member_offset(Draw_Instance, "radii")},
        .{location = 3, format = .R32G32B32A32_SFLOAT, offset = #run member_offset(Draw_Instance, "clip")},
        .{location = 4, format = .R8G8B8A8_UNORM,      offset = #run member_offset(Draw_Instance, "color0")},
        .{location = 5, format = .R8G8B8A8_UNORM,      offset = #run member_offset(Draw_Instance, "color1")},
        .{location = 6, format = .R8G8B8A8_UNORM,      offset = #run member_offset(Draw_Instance, "border_color")},
        .{location = 7, format = .R32_UINT,            offset = #run member_offset(Draw_Instance, "kind")},
        .{location = 8, format = .R32G32B32A32_SFLOAT, offset = #run member_offset(Draw_Instance, "params")},
    ];
    vertex_input := VkPipelineVertexInputStateCreateInfo.{
        vertexBindingDescriptionCount = 1, pVertexBindingDescriptions = *binding,
        vertexAttributeDescriptionCount = attributes.count, pVertexAttributeDescriptions = attributes.data,
    };
    assembly := VkPipelineInputAssemblyStateCreateInfo.{topology = .TRIANGLE_STRIP};
    viewport := VkPipelineViewportStateCreateInfo.{viewportCount = 1, scissorCount = 1};
    raster := VkPipelineRasterizationStateCreateInfo.{polygonMode = .FILL, cullMode = .NONE, frontFace = .COUNTER_CLOCKWISE, lineWidth = 1};
    multisample := VkPipelineMultisampleStateCreateInfo.{rasterizationSamples = ._1_BIT};
    // Premultiplied alpha.
    blend_attachment := VkPipelineColorBlendAttachmentState.{
        blendEnable = VK_TRUE,
        srcColorBlendFactor = .ONE, dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA, colorBlendOp = .ADD,
        srcAlphaBlendFactor = .ONE, dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA, alphaBlendOp = .ADD,
        colorWriteMask = .R_BIT | .G_BIT | .B_BIT | .A_BIT,
    };
    blend := VkPipelineColorBlendStateCreateInfo.{attachmentCount = 1, pAttachments = *blend_attachment};
    dynamic_states := VkDynamicState.[.VIEWPORT, .SCISSOR];
    dynamic := VkPipelineDynamicStateCreateInfo.{dynamicStateCount = dynamic_states.count, pDynamicStates = dynamic_states.data};

    info := VkGraphicsPipelineCreateInfo.{
        stageCount          = stages.count,
        pStages             = stages.data,
        pVertexInputState   = *vertex_input,
        pInputAssemblyState = *assembly,
        pViewportState      = *viewport,
        pRasterizationState = *raster,
        pMultisampleState   = *multisample,
        pColorBlendState    = *blend,
        pDynamicState       = *dynamic,
        layout              = vk.pipeline_layout,
        renderPass          = vk.render_pass,
    };
    if vk_call.CreateGraphicsPipelines(vk.device, null, 1, *info, null, *vk.pipeline) != .SUCCESS return fail("vkCreateGraphicsPipelines");
    return true;
}

create_shader_module :: (code: [] u32) -> VkShaderModule {
    info := VkShaderModuleCreateInfo.{codeSize = xx (code.count * 4), pCode = code.data};
    module: VkShaderModule;
    if vk_call.CreateShaderModule(vk.device, *info, null, *module) != .SUCCESS return null;
    return module;
}

create_frames :: () -> bool {
    commands: [FRAMES] VkCommandBuffer;
    allocate := VkCommandBufferAllocateInfo.{commandPool = vk.command_pool, level = .PRIMARY, commandBufferCount = FRAMES};
    if vk_call.AllocateCommandBuffers(vk.device, *allocate, commands.data) != .SUCCESS return fail("vkAllocateCommandBuffers");
    layouts: [FRAMES] VkDescriptorSetLayout;
    for * layouts it.* = vk.set_layout;
    sets: [FRAMES] VkDescriptorSet;
    set_info := VkDescriptorSetAllocateInfo.{descriptorPool = vk.descriptor_pool, descriptorSetCount = FRAMES, pSetLayouts = layouts.data};
    if vk_call.AllocateDescriptorSets(vk.device, *set_info, sets.data) != .SUCCESS return fail("vkAllocateDescriptorSets");

    for * vk.frames {
        it.commands   = commands[it_index];
        it.descriptor = sets[it_index];
        fence_info: VkFenceCreateInfo;
        semaphore_info: VkSemaphoreCreateInfo;
        if vk_call.CreateFence(vk.device, *fence_info, null, *it.fence) != .SUCCESS return fail("vkCreateFence");
        if vk_call.CreateSemaphore(vk.device, *semaphore_info, null, *it.acquired) != .SUCCESS return fail("vkCreateSemaphore");
    }
    return true;
}

// Ends this frame's commands and submits them: they wait for the swapchain
// image and signal that it is drawn (for the present) and the frame's fence.
submit :: (frame: *Frame_Slot) -> bool {
    vk_call.EndCommandBuffer(frame.commands);
    vk_call.ResetFences(vk.device, 1, *frame.fence);
    wait_stage := VkPipelineStageFlags.COLOR_ATTACHMENT_OUTPUT_BIT;
    info := VkSubmitInfo.{
        waitSemaphoreCount   = 1,
        pWaitSemaphores      = *frame.acquired,
        pWaitDstStageMask    = *wait_stage,
        commandBufferCount   = 1,
        pCommandBuffers      = *frame.commands,
        signalSemaphoreCount = 1,
        pSignalSemaphores    = *vk.rendered[vk.image_index],
    };
    result := vk_call.QueueSubmit(vk.queue, 1, *info, frame.fence);
    vk.committed = true;
    if result != .SUCCESS {
        if result == .ERROR_DEVICE_LOST device_lost();
        else fail("vkQueueSubmit");
        return false;
    }
    frame.submitted = true;
    return true;
}

// Driver update, GPU reset: start over. Everything the GPU had is rebuilt
// from CPU-side state, the atlases included.
device_lost :: () {
    log_error("The graphics device was lost; recreating it.\n");
    renderer_shutdown();
    if !renderer_init() { platform.quit_requested = true; return; }
    for atlas: (*Glyph_Atlas).[*glyph_atlas, *color_atlas] {
        atlas.generation += 1;
        atlas.dirty_x0, atlas.dirty_y0 = 0, 0;
        atlas.dirty_x1, atlas.dirty_y1 = atlas.size, atlas.size;
    }
}

upload_instances :: (frame: *Frame_Slot) -> int {
    count := draw.instances.count;
    if count == 0 return 0;
    bytes := count * size_of(Draw_Instance);
    if bytes > frame.instances.size {
        capacity := max(frame.instances.size * 2, 4096 * size_of(Draw_Instance));
        while capacity < bytes capacity *= 2;
        destroy_buffer(*frame.instances);   // This slot's fence was waited on: unused.
        // Where the GPU reads it fastest and the CPU can still write it
        // (resizable BAR, integrated GPUs), else anywhere the CPU can.
        if !create_buffer(*frame.instances, capacity, .VERTEX_BUFFER_BIT, .DEVICE_LOCAL_BIT | .HOST_VISIBLE_BIT | .HOST_COHERENT_BIT)
           && !create_buffer(*frame.instances, capacity, .VERTEX_BUFFER_BIT, .HOST_VISIBLE_BIT | .HOST_COHERENT_BIT) {
            fail("Creating the instance buffer");
            return 0;
        }
    }
    memcpy(frame.instances.mapped, draw.instances.data, bytes);
    renderer_stats.upload_bytes += bytes;
    return count;
}

upload_atlas :: (commands: VkCommandBuffer, frame: *Frame_Slot, gpu: *Atlas_Image, atlas: *Glyph_Atlas, format: VkFormat) {
    size := max(atlas.size, 1);   // An empty atlas still needs an image to bind.
    if !gpu.image || gpu.generation != atlas.generation || gpu.size != size {
        // Frames in flight may still sample the old one.
        if gpu.image array_add(*frame.garbage, gpu.*);
        gpu.* = .{};
        if !create_atlas_image(gpu, size, format) { fail("Creating an atlas image"); return; }
        gpu.generation = atlas.generation;
        if atlas.size {
            atlas.dirty_x0, atlas.dirty_y0 = 0, 0;
            atlas.dirty_x1, atlas.dirty_y1 = atlas.size, atlas.size;
        }
    }
    if !gpu.ready || (atlas.size && atlas.dirty_x0 < atlas.dirty_x1 && atlas.dirty_y0 < atlas.dirty_y1) {
        x0, y0, x1, y1 := 0, 0, 1, 1;
        if atlas.size {
            x0, y0, x1, y1 = atlas.dirty_x0, atlas.dirty_y0, atlas.dirty_x1, atlas.dirty_y1;
            if x0 >= x1 || y0 >= y1 x0, y0, x1, y1 = 0, 0, 1, 1;   // Only giving the new image a layout.
        }
        bpp := atlas.bytes_per_pixel;
        w, h := x1 - x0, y1 - y0;
        bytes := w * h * bpp;
        // Rows packed one after another into this frame's staging buffer.
        if frame.staging.size < bytes {
            destroy_buffer(*frame.staging);
            if !create_buffer(*frame.staging, max(bytes, 256 * 1024), .TRANSFER_SRC_BIT, .HOST_VISIBLE_BIT | .HOST_COHERENT_BIT) {
                fail("Creating the atlas staging buffer");
                return;
            }
        }
        dst := cast(*u8) frame.staging.mapped;
        if atlas.size {
            for y: y0..y1 - 1 memcpy(dst + (y - y0) * w * bpp, atlas.pixels.data + (y * atlas.size + x0) * bpp, w * bpp);
        } else {
            memset(dst, 0, bytes);
        }

        // Earlier frames' sampling is done before the copy; this one's waits for it.
        to_copy := image_barrier(gpu.image, ifx gpu.ready then .SHADER_READ_ONLY_OPTIMAL else .UNDEFINED, .TRANSFER_DST_OPTIMAL, 0, .TRANSFER_WRITE_BIT);
        vk_call.CmdPipelineBarrier(commands, .FRAGMENT_SHADER_BIT, .TRANSFER_BIT, 0, 0, null, 0, null, 1, *to_copy);
        region := VkBufferImageCopy.{
            imageSubresource = .{aspectMask = .COLOR_BIT, layerCount = 1},
            imageOffset      = .{xx x0, xx y0, 0},
            imageExtent      = .{xx w, xx h, 1},
        };
        vk_call.CmdCopyBufferToImage(commands, frame.staging.buffer, gpu.image, .TRANSFER_DST_OPTIMAL, 1, *region);
        to_read := image_barrier(gpu.image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL, .TRANSFER_WRITE_BIT, .SHADER_READ_BIT);
        vk_call.CmdPipelineBarrier(commands, .TRANSFER_BIT, .FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, *to_read);
        gpu.ready = true;
        if atlas.size renderer_stats.upload_bytes += bytes;
    }
    atlas.dirty_x0, atlas.dirty_y0 = atlas.size, atlas.size;
    atlas.dirty_x1, atlas.dirty_y1 = 0, 0;
}

// Points this frame's descriptor set at the current atlases. Its fence has
// been waited on, so no frame in flight uses the set.
bind_atlases :: (frame: *Frame_Slot) {
    if frame.bound_glyph == vk.glyph_atlas.view && frame.bound_color == vk.color_atlas.view return;
    images := VkDescriptorImageInfo.[
        .{imageView = vk.glyph_atlas.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL},
        .{imageView = vk.color_atlas.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL},
    ];
    writes := VkWriteDescriptorSet.[
        .{dstSet = frame.descriptor, dstBinding = 0, descriptorCount = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, pImageInfo = *images[0]},
        .{dstSet = frame.descriptor, dstBinding = 1, descriptorCount = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, pImageInfo = *images[1]},
    ];
    vk_call.UpdateDescriptorSets(vk.device, writes.count, writes.data, 0, null);
    frame.bound_glyph = vk.glyph_atlas.view;
    frame.bound_color = vk.color_atlas.view;
}

image_barrier :: (image: VkImage, from: VkImageLayout, to: VkImageLayout, src: VkAccessFlags, dst: VkAccessFlags) -> VkImageMemoryBarrier {
    return .{
        srcAccessMask       = src,
        dstAccessMask       = dst,
        oldLayout           = from,
        newLayout           = to,
        srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        image               = image,
        subresourceRange    = .{aspectMask = .COLOR_BIT, levelCount = 1, layerCount = 1},
    };
}

create_atlas_image :: (gpu: *Atlas_Image, size: s32, format: VkFormat) -> bool {
    info := VkImageCreateInfo.{
        imageType = ._2D, format = format, extent = .{xx size, xx size, 1},
        mipLevels = 1, arrayLayers = 1, samples = ._1_BIT, tiling = .OPTIMAL,
        usage = .SAMPLED_BIT | .TRANSFER_DST_BIT, sharingMode = .EXCLUSIVE, initialLayout = .UNDEFINED,
    };
    if vk_call.CreateImage(vk.device, *info, null, *gpu.image) != .SUCCESS return false;
    requirements: VkMemoryRequirements;
    vk_call.GetImageMemoryRequirements(vk.device, gpu.image, *requirements);
    if !allocate(requirements, .DEVICE_LOCAL_BIT, *gpu.memory) && !allocate(requirements, 0, *gpu.memory) {
        destroy_atlas_image(gpu);
        return false;
    }
    vk_call.BindImageMemory(vk.device, gpu.image, gpu.memory, 0);
    view_info := VkImageViewCreateInfo.{
        image = gpu.image, viewType = ._2D, format = format,
        subresourceRange = .{aspectMask = .COLOR_BIT, levelCount = 1, layerCount = 1},
    };
    if vk_call.CreateImageView(vk.device, *view_info, null, *gpu.view) != .SUCCESS { destroy_atlas_image(gpu); return false; }
    gpu.size = size;
    return true;
}

destroy_atlas_image :: (gpu: *Atlas_Image) {
    if gpu.view   vk_call.DestroyImageView(vk.device, gpu.view, null);
    if gpu.image  vk_call.DestroyImage(vk.device, gpu.image, null);
    if gpu.memory vk_call.FreeMemory(vk.device, gpu.memory, null);
    gpu.* = .{};
}

// A buffer the CPU writes (or reads) through a pointer kept mapped.
create_buffer :: (b: *Buffer, size: int, usage: VkBufferUsageFlags, properties: VkMemoryPropertyFlags) -> bool {
    info := VkBufferCreateInfo.{size = xx size, usage = usage, sharingMode = .EXCLUSIVE};
    if vk_call.CreateBuffer(vk.device, *info, null, *b.buffer) != .SUCCESS return false;
    requirements: VkMemoryRequirements;
    vk_call.GetBufferMemoryRequirements(vk.device, b.buffer, *requirements);
    if !allocate(requirements, properties, *b.memory)
       || vk_call.BindBufferMemory(vk.device, b.buffer, b.memory, 0) != .SUCCESS
       || vk_call.MapMemory(vk.device, b.memory, 0, xx size, 0, *b.mapped) != .SUCCESS {
        destroy_buffer(b);
        return false;
    }
    b.size = size;
    return true;
}

destroy_buffer :: (b: *Buffer) {
    if b.buffer vk_call.DestroyBuffer(vk.device, b.buffer, null);
    if b.memory vk_call.FreeMemory(vk.device, b.memory, null);   // Unmaps it.
    b.* = .{};
}

allocate :: (requirements: VkMemoryRequirements, properties: VkMemoryPropertyFlags, memory: *VkDeviceMemory) -> bool {
    for 0..vk.memory.memoryTypeCount - 1 {
        if !(requirements.memoryTypeBits & (1 << it)) continue;
        if (vk.memory.memoryTypes[it].propertyFlags & properties) != properties continue;
        info := VkMemoryAllocateInfo.{allocationSize = requirements.size, memoryTypeIndex = it};
        return vk_call.AllocateMemory(vk.device, *info, null, memory) == .SUCCESS;
    }
    return false;
}

fail :: (what: string) -> bool {
    log_error("Vulkan: % failed.\n", what);
    return false;
}

member_offset :: (T: Type, name: string) -> u32 {
    info := cast(*Type_Info_Struct) T;
    for info.members if it.name == name return cast(u32) it.offset_in_bytes;
    assert(false, "No member % in %", name, T);
    return 0;
}

// Newer than the Vulkan module's headers (1.1.85).

VkXlibSurfaceCreateInfoKHR :: struct {
    sType:  VkStructureType = xx 1000004000;   // VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR
    pNext:  *void;
    flags:  u32;
    dpy:    *void;   // Display*
    window: u64;     // Window
}
PFN_vkCreateXlibSurfaceKHR :: #type (instance: VkInstance, pCreateInfo: *VkXlibSurfaceCreateInfoKHR, pAllocator: *VkAllocationCallbacks, pSurface: *VkSurfaceKHR) -> VkResult #c_call;

VkWaylandSurfaceCreateInfoKHR :: struct {
    sType:   VkStructureType = xx 1000006000;   // VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR
    pNext:   *void;
    flags:   u32;
    display: *void;   // wl_display*
    surface: *void;   // wl_surface*
}
PFN_vkCreateWaylandSurfaceKHR :: #type (instance: VkInstance, pCreateInfo: *VkWaylandSurfaceCreateInfoKHR, pAllocator: *VkAllocationCallbacks, pSurface: *VkSurfaceKHR) -> VkResult #c_call;

VkPresentIdKHR :: struct {
    sType:          VkStructureType = xx 1000294000;   // VK_STRUCTURE_TYPE_PRESENT_ID_KHR
    pNext:          *void;
    swapchainCount: u32;
    pPresentIds:    *u64;
}

VkPhysicalDevicePresentIdFeaturesKHR :: struct {
    sType:     VkStructureType = xx 1000294001;   // VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_ID_FEATURES_KHR
    pNext:     *void;
    presentId: VkBool32;
}

VkPhysicalDevicePresentWaitFeaturesKHR :: struct {
    sType:       VkStructureType = xx 1000248000;   // VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_WAIT_FEATURES_KHR
    pNext:       *void;
    presentWait: VkBool32;
}

PFN_vkWaitForPresentKHR :: #type (device: VkDevice, swapchain: VkSwapchainKHR, presentId: u64, timeout: u64) -> VkResult #c_call;
