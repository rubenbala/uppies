// Renderer front end. A backend per graphics API implements:
//
//   renderer_init() -> bool              after platform_init
//   renderer_shutdown()
//   renderer_wait_for_frame()            blocks until the display can take a
//                                        new frame (lowest-latency pacing);
//                                        does nothing if already waited
//                                        and not presented since
//   renderer_render(clear: Color)        draws `draw.instances`
//   renderer_present()
//
// Today: Direct3D 11 on Windows. Metal (macOS) and Vulkan (Linux) take the
// same draw list and the same shading model.

Renderer_Stats :: struct {
    instances:     int;
    draw_calls:    int;
    upload_bytes:  int;   // Instance + atlas bytes sent to the GPU this frame.
}

Renderer_Settings :: struct {
    vsync := true;
}

renderer_stats: Renderer_Stats;
renderer_settings: Renderer_Settings;

#if OS == .WINDOWS {
    #load "d3d11/renderer_d3d11.jai";
}
