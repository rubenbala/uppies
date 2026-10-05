// Direct3D 11 backend.
//
// Why D3D11 rather than D3D12 for a UI: a frame here is one instanced draw.
// D3D12's wins (cheap draw submission, explicit multithreading) don't apply
// at one draw, and D3D11 gives the same GPU work with far less to get wrong.
// What does matter is presentation, and that is done the modern way:
//
// - Flip-model swap chain (FLIP_DISCARD): no copy into a redirection
//   surface, eligible for independent flip and hardware overlays.
// - Frame latency waitable object with a maximum latency of one frame: we
//   wait until the display can take a frame *before* reading input and
//   building the UI, so what is shown is never more than a frame old.
// - Tearing allowed when vsync is off, for uncapped rendering and variable
//   refresh rate displays.

renderer_init :: () -> bool {
    if !create_device() return false;
    if !create_swap_chain() return false;
    if !create_pipeline() return false;
    return true;
}

renderer_shutdown :: () {
    if d3d.device_context ID3D11DeviceContext_ClearState(d3d.device_context);
    release_back_buffer();
    if d3d.frame_waitable CloseHandle(d3d.frame_waitable);
    safe_release(d3d.atlas_srv);
    safe_release(d3d.atlas_texture);
    safe_release(d3d.instance_buffer);
    safe_release(d3d.frame_constants);
    safe_release(d3d.input_layout);
    safe_release(d3d.vertex_shader);
    safe_release(d3d.pixel_shader);
    safe_release(d3d.blend_state);
    safe_release(d3d.rasterizer_state);
    safe_release(d3d.sampler);
    safe_release(d3d.swap_chain2);
    safe_release(d3d.swap_chain);
    safe_release(d3d.device_context);
    safe_release(d3d.device);
    d3d = .{};
}

renderer_wait_for_frame :: () {
    if d3d.frame_waitable WaitForSingleObjectEx(d3d.frame_waitable, 1000, 1);
}

renderer_render :: (clear: Color) {
    renderer_stats = .{};
    if !d3d.device return;
    ctx := d3d.device_context;

    if platform.width != d3d.width || platform.height != d3d.height {
        if !resize_swap_chain(platform.width, platform.height) return;
    }
    upload_atlas();
    count := upload_instances();

    // Constants.
    {
        mapped: D3D11_MAPPED_SUBRESOURCE;
        if SUCCEEDED(ID3D11DeviceContext_Map(ctx, d3d.frame_constants, 0, .WRITE_DISCARD, 0, *mapped)) {
            constants := cast(*Frame_Constants) mapped.pData;
            constants.viewport_size  = .[cast(float) d3d.width, cast(float) d3d.height];
            constants.atlas_inv_size = .[1.0 / glyph_atlas.size, 1.0 / glyph_atlas.size];
            ID3D11DeviceContext_Unmap(ctx, d3d.frame_constants, 0);
        }
    }

    viewport: D3D11_VIEWPORT;
    viewport.Width    = xx d3d.width;
    viewport.Height   = xx d3d.height;
    viewport.MaxDepth = 1;

    clear_color: [4] float = ---;
    for 0..3 clear_color[it] = ((clear >> (it * 8)) & 0xFF) / 255.0;

    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, *d3d.back_buffer_rtv, null);
    ID3D11DeviceContext_ClearRenderTargetView(ctx, d3d.back_buffer_rtv, *clear_color);
    if count == 0 return;

    stride: u32 = size_of(Draw_Instance);
    offset: u32 = 0;
    ID3D11DeviceContext_RSSetViewports(ctx, 1, *viewport);
    ID3D11DeviceContext_RSSetState(ctx, d3d.rasterizer_state);
    ID3D11DeviceContext_OMSetBlendState(ctx, d3d.blend_state, null, 0xFFFF_FFFF);
    ID3D11DeviceContext_IASetInputLayout(ctx, d3d.input_layout);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, .TRIANGLESTRIP);
    ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, *d3d.instance_buffer, *stride, *offset);
    ID3D11DeviceContext_VSSetShader(ctx, d3d.vertex_shader, null, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(ctx, 0, 1, *d3d.frame_constants);
    ID3D11DeviceContext_PSSetShader(ctx, d3d.pixel_shader, null, 0);
    ID3D11DeviceContext_PSSetConstantBuffers(ctx, 0, 1, *d3d.frame_constants);
    ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, *d3d.atlas_srv);
    ID3D11DeviceContext_PSSetSamplers(ctx, 0, 1, *d3d.sampler);
    ID3D11DeviceContext_DrawInstanced(ctx, 4, xx count, 0, 0);

    renderer_stats.instances  = count;
    renderer_stats.draw_calls = 1;
}

renderer_present :: () {
    if !d3d.swap_chain return;
    hr: HRESULT;
    if renderer_settings.vsync {
        hr = IDXGISwapChain_Present(d3d.swap_chain, 1, 0);
    } else {
        flags: u32 = ifx d3d.tearing_supported then cast(u32) DXGI_PRESENT.ALLOW_TEARING else 0;
        hr = IDXGISwapChain_Present(d3d.swap_chain, 0, flags);
    }
    code := cast,no_check(u32) hr;
    if code == DXGI_ERROR_DEVICE_REMOVED || code == DXGI_ERROR_DEVICE_RESET {
        // Driver update, GPU reset, adapter removed: start over. Everything
        // the GPU had is rebuilt from CPU-side state (the atlas included).
        log_error("The graphics device was lost; recreating it.\n");
        renderer_shutdown();
        if !renderer_init() platform.quit_requested = true;
        glyph_atlas.generation += 1;
        glyph_atlas.dirty_x0, glyph_atlas.dirty_y0 = 0, 0;
        glyph_atlas.dirty_x1, glyph_atlas.dirty_y1 = glyph_atlas.size, glyph_atlas.size;
    }
}

renderer_tearing_supported :: () -> bool { return d3d.tearing_supported; }

// Reads back the frame just rendered (call between renderer_render and
// renderer_present) and writes it as a PNG. For screenshots and tests.
renderer_capture_png :: (path: string) -> bool {
    if !d3d.device || !d3d.swap_chain return false;
    back_buffer: *ID3D11Texture2D;
    iid := uid(ID3D11Texture2D_UUID);
    if FAILED(IDXGISwapChain_GetBuffer(d3d.swap_chain, 0, *iid, xx *back_buffer)) return fail("GetBuffer(capture)");
    defer safe_release(back_buffer);

    desc: D3D11_TEXTURE2D_DESC;
    ID3D11Texture2D_GetDesc(back_buffer, *desc);
    desc.Usage          = .STAGING;
    desc.BindFlags      = 0;
    desc.CPUAccessFlags = .READ;
    desc.MiscFlags      = 0;
    staging: *ID3D11Texture2D;
    if FAILED(ID3D11Device_CreateTexture2D(d3d.device, *desc, null, *staging)) return fail("CreateTexture2D(staging)");
    defer safe_release(staging);
    ID3D11DeviceContext_CopyResource(d3d.device_context, staging, back_buffer);

    mapped: D3D11_MAPPED_SUBRESOURCE;
    if FAILED(ID3D11DeviceContext_Map(d3d.device_context, staging, 0, .READ, 0, *mapped)) return fail("Map(staging)");
    w := cast(s32) desc.Width;
    h := cast(s32) desc.Height;
    rgb := NewArray(w * h * 3, u8,, temp);
    for y: 0..h - 1 {
        src := cast(*u8) mapped.pData + y * cast(s64) mapped.RowPitch;
        dst := rgb.data + y * w * 3;
        for x: 0..w - 1 {
            dst[x * 3 + 0] = src[x * 4 + 2];   // BGRA -> RGB
            dst[x * 3 + 1] = src[x * 4 + 1];
            dst[x * 3 + 2] = src[x * 4 + 0];
        }
    }
    ID3D11DeviceContext_Unmap(d3d.device_context, staging, 0);
    return write_png_rgb(path, w, h, rgb.data);
}

#scope_file

D3D_State :: struct {
    device:      *ID3D11Device;
    device_context: *ID3D11DeviceContext;
    swap_chain:  *IDXGISwapChain1;
    swap_chain2: *IDXGISwapChain2;
    frame_waitable: HANDLE;
    swap_chain_flags: u32;
    tearing_supported: bool;

    back_buffer_rtv: *ID3D11RenderTargetView;
    width, height: s32;

    vertex_shader:    *ID3D11VertexShader;
    pixel_shader:     *ID3D11PixelShader;
    input_layout:     *ID3D11InputLayout;
    blend_state:      *ID3D11BlendState;
    rasterizer_state: *ID3D11RasterizerState;
    sampler:          *ID3D11SamplerState;
    frame_constants:  *ID3D11Buffer;

    instance_buffer:   *ID3D11Buffer;
    instance_capacity: int;

    atlas_texture:    *ID3D11Texture2D;
    atlas_srv:        *ID3D11ShaderResourceView;
    atlas_generation: u32;
}

d3d: D3D_State;

Frame_Constants :: struct {
    viewport_size:  [2] float;
    atlas_inv_size: [2] float;
}

BACK_BUFFER_FORMAT :: DXGI_FORMAT.B8G8R8A8_UNORM;

create_device :: () -> bool {
    flags := D3D11_CREATE_DEVICE_FLAG.BGRA_SUPPORT | .SINGLETHREADED;
    #if !APP_RELEASE flags |= .DEBUG;
    levels := D3D_FEATURE_LEVEL.[._11_1, ._11_0];
    level: D3D_FEATURE_LEVEL;

    hr := D3D11CreateDevice(null, .HARDWARE, null, flags, levels.data, levels.count, D3D11_SDK_VERSION, *d3d.device, *level, *d3d.device_context);
    if FAILED(hr) && (flags & .DEBUG) {
        // The debug layer is an optional Windows feature (Graphics Tools).
        flags &= ~.DEBUG;
        hr = D3D11CreateDevice(null, .HARDWARE, null, flags, levels.data, levels.count, D3D11_SDK_VERSION, *d3d.device, *level, *d3d.device_context);
    }
    if FAILED(hr) {
        // Feature level 11_1 unknown to the runtime (Windows 7): ask for 11_0.
        hr = D3D11CreateDevice(null, .HARDWARE, null, flags, levels.data + 1, 1, D3D11_SDK_VERSION, *d3d.device, *level, *d3d.device_context);
    }
    if FAILED(hr) {
        log_error("D3D11CreateDevice failed (0x%).\n", formatInt(cast,no_check(u32) hr, base = 16));
        return false;
    }
    log("Direct3D 11 device, feature level %, debug layer %\n", level, ifx flags & .DEBUG then "on" else "off");
    return true;
}

create_swap_chain :: () -> bool {
    // The factory that made the device's adapter.
    dxgi_device: *IDXGIDevice;
    adapter: *IDXGIAdapter;
    factory: *IDXGIFactory2;
    defer safe_release(dxgi_device);
    defer safe_release(adapter);
    defer safe_release(factory);

    iid := uid(IDXGIDevice_UUID);
    if FAILED(IUnknown_QueryInterface(d3d.device, *iid, xx *dxgi_device)) return fail("QueryInterface(IDXGIDevice)");
    if FAILED(IDXGIDevice_GetAdapter(dxgi_device, *adapter)) return fail("GetAdapter");
    iid = uid(IDXGIFactory2_UUID);
    if FAILED(IDXGIObject_GetParent(adapter, *iid, xx *factory)) return fail("GetParent(IDXGIFactory2)");

    {
        desc: DXGI_ADAPTER_DESC;
        if SUCCEEDED(IDXGIAdapter_GetDesc(adapter, *desc)) {
            name := wide_to_utf8(cast(*u16) desc.Description.data,, temp);
            log("GPU: %\n", name);
        }
    }

    // Tearing support (DXGI 1.5): needed for vsync off with a flip model.
    {
        factory5: *IDXGIFactory5;
        iid = uid(IDXGIFactory5_UUID);
        if SUCCEEDED(IUnknown_QueryInterface(factory, *iid, xx *factory5)) {
            allow: s32;
            if SUCCEEDED(IDXGIFactory5_CheckFeatureSupport(factory5, .PRESENT_ALLOW_TEARING, *allow, size_of(s32))) {
                d3d.tearing_supported = allow != 0;
            }
            safe_release(factory5);
        }
    }

    d3d.swap_chain_flags = cast(u32) DXGI_SWAP_CHAIN_FLAG.FRAME_LATENCY_WAITABLE_OBJECT;
    if d3d.tearing_supported d3d.swap_chain_flags |= cast(u32) DXGI_SWAP_CHAIN_FLAG.ALLOW_TEARING;

    d3d.width  = max(platform.width, 1);
    d3d.height = max(platform.height, 1);

    desc: DXGI_SWAP_CHAIN_DESC1;
    desc.Width       = xx d3d.width;
    desc.Height      = xx d3d.height;
    desc.Format      = BACK_BUFFER_FORMAT;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = .RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.Scaling     = .NONE;            // While resizing, show old frames unstretched.
    desc.SwapEffect  = .FLIP_DISCARD;
    desc.AlphaMode   = .IGNORE;
    desc.Flags       = d3d.swap_chain_flags;

    if FAILED(IDXGIFactory2_CreateSwapChainForHwnd(factory, d3d.device, platform_window, *desc, null, null, *d3d.swap_chain)) {
        return fail("CreateSwapChainForHwnd");
    }
    // We handle fullscreen ourselves; no DXGI Alt+Enter.
    IDXGIFactory_MakeWindowAssociation(factory, platform_window, cast(u32) DXGI_MWA.NO_ALT_ENTER);

    iid = uid(IDXGISwapChain2_UUID);
    if FAILED(IUnknown_QueryInterface(d3d.swap_chain, *iid, xx *d3d.swap_chain2)) return fail("QueryInterface(IDXGISwapChain2)");
    IDXGISwapChain2_SetMaximumFrameLatency(d3d.swap_chain2, 1);
    d3d.frame_waitable = IDXGISwapChain2_GetFrameLatencyWaitableObject(d3d.swap_chain2);

    log("Swap chain: flip discard, frame latency 1, tearing %\n", ifx d3d.tearing_supported then "supported" else "unsupported");
    return create_back_buffer();
}

create_back_buffer :: () -> bool {
    back_buffer: *ID3D11Texture2D;
    iid := uid(ID3D11Texture2D_UUID);
    if FAILED(IDXGISwapChain_GetBuffer(d3d.swap_chain, 0, *iid, xx *back_buffer)) return fail("GetBuffer");
    defer safe_release(back_buffer);
    if FAILED(ID3D11Device_CreateRenderTargetView(d3d.device, back_buffer, null, *d3d.back_buffer_rtv)) return fail("CreateRenderTargetView");
    return true;
}

release_back_buffer :: () {
    if d3d.device_context ID3D11DeviceContext_OMSetRenderTargets(d3d.device_context, 0, null, null);
    safe_release(d3d.back_buffer_rtv);
    d3d.back_buffer_rtv = null;
}

resize_swap_chain :: (width: s32, height: s32) -> bool {
    if width <= 0 || height <= 0 return false;
    release_back_buffer();
    ID3D11DeviceContext_Flush(d3d.device_context);
    if FAILED(IDXGISwapChain_ResizeBuffers(d3d.swap_chain, 0, xx width, xx height, .UNKNOWN, d3d.swap_chain_flags)) {
        return fail("ResizeBuffers");
    }
    d3d.width  = width;
    d3d.height = height;
    return create_back_buffer();
}

create_pipeline :: () -> bool {
    device := d3d.device;
    if FAILED(ID3D11Device_CreateVertexShader(device, shader_ui_vs.data, shader_ui_vs.count, null, *d3d.vertex_shader)) return fail("CreateVertexShader");
    if FAILED(ID3D11Device_CreatePixelShader(device, shader_ui_ps.data, shader_ui_ps.count, null, *d3d.pixel_shader)) return fail("CreatePixelShader");

    // Every attribute is per instance; the vertex shader makes the corners
    // from SV_VertexID, so there is no vertex or index buffer at all.
    element :: (name: *u8, index: u32, format: DXGI_FORMAT, offset: u32) -> D3D11_INPUT_ELEMENT_DESC {
        e: D3D11_INPUT_ELEMENT_DESC;
        e.SemanticName         = name;
        e.SemanticIndex        = index;
        e.Format               = format;
        e.AlignedByteOffset    = offset;
        e.InputSlotClass       = .INSTANCE_DATA;
        e.InstanceDataStepRate = 1;
        return e;
    }
    I :: Draw_Instance;
    layout := D3D11_INPUT_ELEMENT_DESC.[
        element("RECT",   0, .R32G32B32A32_FLOAT, #run member_offset(I, "rect")),
        element("UV",     0, .R32G32B32A32_FLOAT, #run member_offset(I, "uv")),
        element("RADII",  0, .R32G32B32A32_FLOAT, #run member_offset(I, "radii")),
        element("CLIP",   0, .R32G32B32A32_FLOAT, #run member_offset(I, "clip")),
        element("COLOR",  0, .R8G8B8A8_UNORM,     #run member_offset(I, "color0")),
        element("COLOR",  1, .R8G8B8A8_UNORM,     #run member_offset(I, "color1")),
        element("COLOR",  2, .R8G8B8A8_UNORM,     #run member_offset(I, "border_color")),
        element("KIND",   0, .R32_UINT,           #run member_offset(I, "kind")),
        element("PARAMS", 0, .R32G32B32A32_FLOAT, #run member_offset(I, "params")),
    ];
    if FAILED(ID3D11Device_CreateInputLayout(device, layout.data, layout.count, shader_ui_vs.data, shader_ui_vs.count, *d3d.input_layout)) return fail("CreateInputLayout");

    // Premultiplied alpha.
    blend: D3D11_BLEND_DESC;
    rt := *blend.RenderTarget[0];
    rt.BlendEnable    = .TRUE;
    rt.SrcBlend       = .ONE;
    rt.DestBlend      = .INV_SRC_ALPHA;
    rt.BlendOp        = .ADD;
    rt.SrcBlendAlpha  = .ONE;
    rt.DestBlendAlpha = .INV_SRC_ALPHA;
    rt.BlendOpAlpha   = .ADD;
    rt.RenderTargetWriteMask = xx D3D11_COLOR_WRITE_ENABLE.ALL;
    if FAILED(ID3D11Device_CreateBlendState(device, *blend, *d3d.blend_state)) return fail("CreateBlendState");

    raster: D3D11_RASTERIZER_DESC;
    raster.FillMode = .SOLID;
    raster.CullMode = .NONE;
    raster.DepthClipEnable = .TRUE;
    if FAILED(ID3D11Device_CreateRasterizerState(device, *raster, *d3d.rasterizer_state)) return fail("CreateRasterizerState");

    sampler: D3D11_SAMPLER_DESC;
    sampler.Filter   = .MIN_MAG_MIP_LINEAR;
    sampler.AddressU = .CLAMP;
    sampler.AddressV = .CLAMP;
    sampler.AddressW = .CLAMP;
    sampler.MaxLOD   = 0;
    if FAILED(ID3D11Device_CreateSamplerState(device, *sampler, *d3d.sampler)) return fail("CreateSamplerState");

    cb: D3D11_BUFFER_DESC;
    cb.ByteWidth      = xx align_up(size_of(Frame_Constants), 16);
    cb.Usage          = .DYNAMIC;
    cb.BindFlags      = .CONSTANT_BUFFER;
    cb.CPUAccessFlags = .WRITE;
    if FAILED(ID3D11Device_CreateBuffer(device, *cb, null, *d3d.frame_constants)) return fail("CreateBuffer(constants)");

    return true;
}

// One map per frame. WRITE_DISCARD hands us fresh memory while the GPU may
// still be reading last frame's copy: no stall.
upload_instances :: () -> int {
    count := draw.instances.count;
    if count == 0 return 0;

    if count > d3d.instance_capacity {
        safe_release(d3d.instance_buffer);
        d3d.instance_buffer = null;
        capacity := max(d3d.instance_capacity * 2, 4096);
        while capacity < count capacity *= 2;

        desc: D3D11_BUFFER_DESC;
        desc.ByteWidth      = xx (capacity * size_of(Draw_Instance));
        desc.Usage          = .DYNAMIC;
        desc.BindFlags      = .VERTEX_BUFFER;
        desc.CPUAccessFlags = .WRITE;
        if FAILED(ID3D11Device_CreateBuffer(d3d.device, *desc, null, *d3d.instance_buffer)) {
            d3d.instance_capacity = 0;
            fail("CreateBuffer(instances)");
            return 0;
        }
        d3d.instance_capacity = capacity;
    }

    mapped: D3D11_MAPPED_SUBRESOURCE;
    if FAILED(ID3D11DeviceContext_Map(d3d.device_context, d3d.instance_buffer, 0, .WRITE_DISCARD, 0, *mapped)) return 0;
    bytes := count * size_of(Draw_Instance);
    memcpy(mapped.pData, draw.instances.data, bytes);
    ID3D11DeviceContext_Unmap(d3d.device_context, d3d.instance_buffer, 0);
    renderer_stats.upload_bytes += bytes;
    return count;
}

// Sends only the part of the atlas that new glyphs touched.
upload_atlas :: () {
    atlas := *glyph_atlas;
    if !d3d.atlas_texture || d3d.atlas_generation != atlas.generation {
        safe_release(d3d.atlas_srv);
        safe_release(d3d.atlas_texture);
        d3d.atlas_srv = null;
        d3d.atlas_texture = null;

        desc: D3D11_TEXTURE2D_DESC;
        desc.Width     = xx atlas.size;
        desc.Height    = xx atlas.size;
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format    = .R8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage     = .DEFAULT;
        desc.BindFlags = .SHADER_RESOURCE;
        if FAILED(ID3D11Device_CreateTexture2D(d3d.device, *desc, null, *d3d.atlas_texture)) { fail("CreateTexture2D(atlas)"); return; }
        if FAILED(ID3D11Device_CreateShaderResourceView(d3d.device, d3d.atlas_texture, null, *d3d.atlas_srv)) { fail("CreateShaderResourceView(atlas)"); return; }
        d3d.atlas_generation = atlas.generation;
        atlas.dirty_x0, atlas.dirty_y0 = 0, 0;
        atlas.dirty_x1, atlas.dirty_y1 = atlas.size, atlas.size;
    }

    if atlas.dirty_x0 >= atlas.dirty_x1 || atlas.dirty_y0 >= atlas.dirty_y1 return;
    box: D3D11_BOX;
    box.left   = xx atlas.dirty_x0;
    box.top    = xx atlas.dirty_y0;
    box.right  = xx atlas.dirty_x1;
    box.bottom = xx atlas.dirty_y1;
    box.front  = 0;
    box.back   = 1;
    src := atlas.pixels.data + atlas.dirty_y0 * atlas.size + atlas.dirty_x0;
    ID3D11DeviceContext_UpdateSubresource(d3d.device_context, d3d.atlas_texture, 0, *box, src, xx atlas.size, 0);
    renderer_stats.upload_bytes += (atlas.dirty_x1 - atlas.dirty_x0) * (atlas.dirty_y1 - atlas.dirty_y0);

    atlas.dirty_x0, atlas.dirty_y0 = atlas.size, atlas.size;
    atlas.dirty_x1, atlas.dirty_y1 = 0, 0;
}

fail :: (what: string) -> bool {
    log_error("Direct3D: % failed.\n", what);
    return false;
}

member_offset :: (T: Type, name: string) -> u32 {
    info := cast(*Type_Info_Struct) T;
    for info.members if it.name == name return cast(u32) it.offset_in_bytes;
    assert(false, "No member % in %", name, T);
    return 0;
}

align_up :: (value: int, alignment: int) -> int {
    return (value + alignment - 1) & ~(alignment - 1);
}

kernel32_lib :: #library,system "kernel32";
WaitForSingleObjectEx :: (handle: HANDLE, milliseconds: u32, alertable: s32) -> u32 #foreign kernel32_lib;
