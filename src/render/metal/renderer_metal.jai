// Metal backend.
//
// The same single instanced draw as the Direct3D 11 backend, with the same
// shader (ui.metal is a port of ui.hlsl), so both look identical. The
// presentation choices mirror the D3D11 ones:
//
// - Two drawables, and the drawable is acquired in renderer_wait_for_frame:
//   nextDrawable blocks until the display has released one, which is what
//   the frame latency waitable does on Windows. We wait *before* reading
//   input and building the UI, so what is shown is never more than a frame
//   old.
// - displaySyncEnabled off when vsync is off: frames present as soon as
//   they're done (uncapped, and adaptive sync on displays that have it).
// - While the window is live-resized, frames present with the Core
//   Animation transaction that resizes the layer, so content never lags or
//   stretches against the window edge.
//
// The shader library is compiled at build time (build.jai runs Xcode's
// metal and metallib) and embedded as shader_ui_metallib.

renderer_init :: () -> bool {
    init_metal();
    init_objective_c_selector_struct(*sel);
    if !platform_metal_layer return fail("No CAMetalLayer");

    mtl.device = xx MTLCreateSystemDefaultDevice();
    if !mtl.device return fail("MTLCreateSystemDefaultDevice");
    mtl.queue = MTLDevice.newCommandQueue(mtl.device);
    if !mtl.queue return fail("newCommandQueue");

    mtl.layer = platform_metal_layer;
    CAMetalLayer.setDevice(mtl.layer, mtl.device);
    CAMetalLayer.setPixelFormat(mtl.layer, DRAWABLE_FORMAT);
    // Captures (renderer_capture_png) read the drawable back; otherwise it
    // only ever is a render target.
    CAMetalLayer.setFramebufferOnly(mtl.layer, xx ifx scripted() then NO else YES);
    apply_vsync();

    if !create_pipeline() return false;
    log("Metal device: %\n", to_string(MTLDevice.name(mtl.device)));
    return true;
}

renderer_shutdown :: () {
    for * mtl.frames {
        if it.commands { MTLCommandBuffer.waitUntilCompleted(it.commands); release(it.commands); }
        if it.instances release(it.instances);
    }
    if mtl.commands release(mtl.commands);
    if mtl.drawable release(mtl.drawable);
    if mtl.atlas    release(mtl.atlas);
    if mtl.pipeline release(mtl.pipeline);
    if mtl.queue    release(mtl.queue);
    if mtl.device   release(mtl.device);
    mtl = .{};
}

// One wait per present: until the next present, waiting again does nothing.
renderer_wait_for_frame :: () {
    if mtl.waited return;
    mtl.waited = true;
    if !mtl.device return;
    acquire_drawable();
}

renderer_render :: (clear: Color) {
    renderer_stats = .{};
    if !mtl.device return;

    pool := objc_init(objc_alloc(NSAutoreleasePool));
    defer NSAutoreleasePool.drain(pool);

    if renderer_settings.vsync != mtl.vsync apply_vsync();
    // Resized since the wait: that drawable is the old size.
    if mtl.drawable && (platform.width != mtl.width || platform.height != mtl.height) {
        release(mtl.drawable);
        mtl.drawable = null;
    }
    if !mtl.drawable acquire_drawable();
    if !mtl.drawable return;

    // This frame's slot in the ring of instance buffers. The GPU finished
    // with it two frames ago; check anyway.
    mtl.frame_index = (mtl.frame_index + 1) % mtl.frames.count;
    frame := *mtl.frames[mtl.frame_index];
    if frame.commands {
        MTLCommandBuffer.waitUntilCompleted(frame.commands);
        release(frame.commands);
        frame.commands = null;
    }

    upload_atlas();
    count := upload_instances(frame);

    mtl.commands = retain(MTLCommandQueue.commandBuffer(mtl.queue));
    mtl.committed = false;
    frame.commands = retain(mtl.commands);

    pass := MTLRenderPassDescriptor.renderPassDescriptor();
    color := MTLRenderPassColorAttachmentDescriptorArray.objectAtIndexedSubscript(MTLRenderPassDescriptor.colorAttachments(pass), 0);
    rgba: [4] float64;
    for 0..3 rgba[it] = ((clear >> (it * 8)) & 0xFF) / 255.0;
    MTLRenderPassColorAttachmentDescriptor.setClearColor(color, MTLClearColorMake(rgba[0], rgba[1], rgba[2], rgba[3]));
    MTLRenderPassAttachmentDescriptor.setLoadAction(color, MTLLoadActionClear);
    MTLRenderPassAttachmentDescriptor.setStoreAction(color, MTLStoreActionStore);
    MTLRenderPassAttachmentDescriptor.setTexture(color, CAMetalDrawable.texture(mtl.drawable));

    encoder := MTLCommandBuffer.renderCommandEncoderWithDescriptor(mtl.commands, pass);
    if count > 0 {
        constants: Frame_Constants;
        constants.viewport_size  = .[cast(float) mtl.width, cast(float) mtl.height];
        constants.atlas_inv_size = .[1.0 / glyph_atlas.size, 1.0 / glyph_atlas.size];
        MTLRenderCommandEncoder.setRenderPipelineState(encoder, xx mtl.pipeline);
        MTLRenderCommandEncoder.setVertexBuffer_offset_atIndex(encoder, xx frame.instances, 0, 0);
        MTLRenderCommandEncoder.setVertexBytes_length_atIndex(encoder, *constants, size_of(Frame_Constants), 1);
        MTLRenderCommandEncoder.setFragmentTexture_atIndex(encoder, xx mtl.atlas, 0);
        MTLRenderCommandEncoder.drawPrimitives_vertexStart_vertexCount_instanceCount(encoder, MTLPrimitiveTypeTriangleStrip, 0, 4, xx count);
        renderer_stats.instances  = count;
        renderer_stats.draw_calls = 1;
    }
    MTLCommandEncoder.endEncoding(xx encoder);
}

renderer_present :: () {
    mtl.waited = false;
    if !mtl.drawable return;
    defer {
        release(mtl.drawable);
        mtl.drawable = null;
        if mtl.commands release(mtl.commands);
        mtl.commands = null;
    }

    pool := objc_init(objc_alloc(NSAutoreleasePool));
    defer NSAutoreleasePool.drain(pool);

    if mtl.committed || !mtl.commands {
        // The frame was committed already (a capture read it back): present
        // with a command buffer of its own.
        if mtl.commands release(mtl.commands);
        mtl.commands = retain(MTLCommandQueue.commandBuffer(mtl.queue));
        mtl.committed = false;
    }

    // During a live resize the layer's new size is part of a Core Animation
    // transaction: present inside it, once the GPU work is scheduled.
    transaction := platform.in_modal_frame;
    if transaction != mtl.transaction {
        mtl.transaction = transaction;
        CAMetalLayer.setPresentsWithTransaction(mtl.layer, xx ifx transaction then YES else NO);
    }
    if transaction {
        MTLCommandBuffer.commit(mtl.commands);
        MTLCommandBuffer.waitUntilScheduled(mtl.commands);
        MTLDrawable.present(xx mtl.drawable);
    } else {
        MTLCommandBuffer.presentDrawable(mtl.commands, xx mtl.drawable);
        MTLCommandBuffer.commit(mtl.commands);
    }
    mtl.committed = true;
}

renderer_tearing_supported :: () -> bool { return true; }

// Reads back the frame just rendered (call between renderer_render and
// renderer_present) and writes it as a PNG. For screenshots and tests.
renderer_capture_png :: (path: string) -> bool {
    if !mtl.drawable || !mtl.commands || mtl.committed return false;
    pool := objc_init(objc_alloc(NSAutoreleasePool));
    defer NSAutoreleasePool.drain(pool);

    w := mtl.width;
    h := mtl.height;
    row := w * 4;
    readback := MTLDevice.newBufferWithLength_options(mtl.device, xx (row * h), MTLResourceStorageModeShared);
    if !readback return fail("newBufferWithLength(capture)");
    defer release(readback);

    blit := MTLCommandBuffer.blitCommandEncoder(mtl.commands);
    MTLBlitCommandEncoder.copyFromTexture_sourceSlice_sourceLevel_sourceOrigin_sourceSize_toBuffer_destinationOffset_destinationBytesPerRow_destinationBytesPerImage(
        blit, CAMetalDrawable.texture(mtl.drawable), 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(xx w, xx h, 1), xx readback, 0, xx row, xx (row * h));
    MTLCommandEncoder.endEncoding(xx blit);
    MTLCommandBuffer.commit(mtl.commands);
    MTLCommandBuffer.waitUntilCompleted(mtl.commands);
    mtl.committed = true;

    src := cast(*u8) MTLBuffer.contents(readback);
    rgb := NewArray(w * h * 3, u8,, temp);
    for y: 0..h - 1 {
        s := src + y * row;
        d := rgb.data + y * w * 3;
        for x: 0..w - 1 {
            d[x * 3 + 0] = s[x * 4 + 2];   // BGRA -> RGB
            d[x * 3 + 1] = s[x * 4 + 1];
            d[x * 3 + 2] = s[x * 4 + 0];
        }
    }
    return write_png_rgb(path, w, h, rgb.data);
}

#scope_file

using,except(Category) ObjC :: #import "Objective_C";
#import "Metal";

Frame_Slot :: struct {
    instances: *MTLBuffer;
    capacity:  int;                // In instances.
    commands:  *MTLCommandBuffer;  // The last frame that read `instances`.
}

Metal_State :: struct {
    device:   *MTLDevice;
    queue:    *MTLCommandQueue;
    layer:    *CAMetalLayer;
    pipeline: *MTLRenderPipelineState;

    drawable:  *CAMetalDrawable;   // Acquired by the wait, released by the present.
    waited:    bool;               // Waited, not presented since.
    width, height: s32;            // Of the drawable.
    commands:  *MTLCommandBuffer;  // This frame's.
    committed: bool;
    vsync:       bool;
    transaction: bool;             // presentsWithTransaction.

    // Instances are written while earlier frames may still be on the GPU:
    // one buffer per frame in flight.
    frames: [3] Frame_Slot;
    frame_index: int;

    atlas: *MTLTexture;
    atlas_generation: u32;
    atlas_size: s32;
}

mtl: Metal_State;

Frame_Constants :: struct {
    viewport_size:  [2] float;
    atlas_inv_size: [2] float;
}

DRAWABLE_FORMAT :: MTLPixelFormatBGRA8Unorm;   // UNORM: blending in sRGB, as on Windows.

// Selectors the Metal module has no wrapper for. Each '_' is a ':'.
Selectors :: struct {
    newLibraryWithData_error_: Selector;
}
sel: Selectors;

fail :: (what: string) -> bool {
    log_error("Metal: % failed.\n", what);
    return false;
}

fail :: (what: string, error: *NSError) -> bool {
    detail := ifx error then to_string(NSError.localizedDescription(error)) else "";
    log_error("Metal: % failed. %\n", what, detail);
    return false;
}

// With vsync, two drawables: the wait blocks until the display has shown
// the last frame. Without, a third lets frames be rendered while the
// compositor holds the other two.
apply_vsync :: () {
    mtl.vsync = renderer_settings.vsync;
    CAMetalLayer.setDisplaySyncEnabled(mtl.layer, xx ifx mtl.vsync then YES else NO);
    CAMetalLayer.setMaximumDrawableCount(mtl.layer, xx ifx mtl.vsync then 2 else 3);
}

acquire_drawable :: () {
    pool := objc_init(objc_alloc(NSAutoreleasePool));
    defer NSAutoreleasePool.drain(pool);
    mtl.width  = max(platform.width, 1);
    mtl.height = max(platform.height, 1);
    CAMetalLayer.setDrawableSize(mtl.layer, .{cast(CGFloat) mtl.width, cast(CGFloat) mtl.height});
    // Blocks until the display frees a drawable (at most about a second,
    // after which it returns null and the frame is skipped).
    drawable := CAMetalLayer.nextDrawable(mtl.layer);
    if drawable mtl.drawable = retain(drawable);
}

create_pipeline :: () -> bool {
    pool := objc_init(objc_alloc(NSAutoreleasePool));
    defer NSAutoreleasePool.drain(pool);

    data := dispatch_data_create(shader_ui_metallib.data, cast(u64) shader_ui_metallib.count, null, null);   // Copied.
    defer release(data);
    error: *NSError;
    newLibraryWithData :: #type (*void, Selector, *void, **NSError) -> *MTLLibrary #c_call;
    library := (cast(newLibraryWithData) objc_msgSend)(mtl.device, sel.newLibraryWithData_error_, data, *error);
    if !library return fail("newLibraryWithData", error);
    defer release(library);

    vs := MTLLibrary.newFunctionWithName(library, NSString.getTempString("vs_main"));
    ps := MTLLibrary.newFunctionWithName(library, NSString.getTempString("ps_main"));
    if !vs || !ps return fail("newFunctionWithName");
    defer { release(vs); release(ps); }

    desc := objc_init(objc_alloc(objc_getClass("MTLRenderPipelineDescriptor")));
    defer release(desc);
    MTLRenderPipelineDescriptor.setVertexFunction(xx desc, vs);
    MTLRenderPipelineDescriptor.setFragmentFunction(xx desc, ps);

    // Premultiplied alpha.
    color := MTLRenderPipelineColorAttachmentDescriptorArray.objectAtIndexedSubscript(MTLRenderPipelineDescriptor.colorAttachments(xx desc), 0);
    MTLRenderPipelineColorAttachmentDescriptor.setPixelFormat(color, DRAWABLE_FORMAT);
    MTLRenderPipelineColorAttachmentDescriptor.setBlendingEnabled(color, YES);
    MTLRenderPipelineColorAttachmentDescriptor.setSourceRGBBlendFactor(color, MTLBlendFactorOne);
    MTLRenderPipelineColorAttachmentDescriptor.setDestinationRGBBlendFactor(color, MTLBlendFactorOneMinusSourceAlpha);
    MTLRenderPipelineColorAttachmentDescriptor.setSourceAlphaBlendFactor(color, MTLBlendFactorOne);
    MTLRenderPipelineColorAttachmentDescriptor.setDestinationAlphaBlendFactor(color, MTLBlendFactorOneMinusSourceAlpha);

    error = null;
    mtl.pipeline = MTLDevice.newRenderPipelineStateWithDescriptor_error(mtl.device, xx desc, *error);
    if !mtl.pipeline return fail("newRenderPipelineState", error);
    return true;
}

upload_instances :: (frame: *Frame_Slot) -> int {
    count := draw.instances.count;
    if count == 0 return 0;

    if count > frame.capacity {
        if frame.instances release(frame.instances);
        frame.instances = null;
        capacity := max(frame.capacity * 2, 4096);
        while capacity < count capacity *= 2;
        frame.instances = MTLDevice.newBufferWithLength_options(mtl.device, xx (capacity * size_of(Draw_Instance)), MTLResourceStorageModeShared);
        if !frame.instances {
            frame.capacity = 0;
            fail("newBufferWithLength(instances)");
            return 0;
        }
        frame.capacity = capacity;
    }

    bytes := count * size_of(Draw_Instance);
    memcpy(MTLBuffer.contents(frame.instances), draw.instances.data, bytes);
    renderer_stats.upload_bytes += bytes;
    return count;
}

upload_atlas :: () {
    atlas := *glyph_atlas;
    if !mtl.atlas || mtl.atlas_generation != atlas.generation || mtl.atlas_size != atlas.size {
        // A frame still on the GPU keeps the old texture alive.
        if mtl.atlas release(mtl.atlas);
        desc := MTLTextureDescriptor.texture2DDescriptorWithPixelFormat_width_height_mipmapped(MTLPixelFormatR8Unorm, xx atlas.size, xx atlas.size, NO);
        MTLTextureDescriptor.setUsage(desc, MTLTextureUsageShaderRead);
        mtl.atlas = xx MTLDevice.newTextureWithDescriptor(mtl.device, desc);
        if !mtl.atlas { fail("newTexture(atlas)"); return; }
        mtl.atlas_generation = atlas.generation;
        mtl.atlas_size = atlas.size;
        atlas.dirty_x0, atlas.dirty_y0 = 0, 0;
        atlas.dirty_x1, atlas.dirty_y1 = atlas.size, atlas.size;
    }

    if atlas.dirty_x0 >= atlas.dirty_x1 || atlas.dirty_y0 >= atlas.dirty_y1 return;
    // New glyphs only ever go to atlas space no frame in flight samples,
    // so writing it now, from the CPU, is safe.
    region: MTLRegion;
    region.origin = MTLOriginMake(xx atlas.dirty_x0, xx atlas.dirty_y0, 0);
    region.size   = MTLSizeMake(xx (atlas.dirty_x1 - atlas.dirty_x0), xx (atlas.dirty_y1 - atlas.dirty_y0), 1);
    src := atlas.pixels.data + atlas.dirty_y0 * atlas.size + atlas.dirty_x0;
    MTLTexture.replaceRegion_mipmapLevel_withBytes_bytesPerRow(mtl.atlas, region, 0, src, xx atlas.size);
    renderer_stats.upload_bytes += (atlas.dirty_x1 - atlas.dirty_x0) * (atlas.dirty_y1 - atlas.dirty_y0);

    atlas.dirty_x0, atlas.dirty_y0 = atlas.size, atlas.size;
    atlas.dirty_x1, atlas.dirty_y1 = 0, 0;
}

libdispatch :: #library,system "libSystem";
dispatch_data_create :: (buffer: *void, size: u64, queue: *void, destructor: *void) -> *void #foreign libdispatch;
