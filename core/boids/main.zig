/// A port of Austin Eng's "computeBoids" webgpu sample.
/// https://github.com/austinEng/webgpu-samples/blob/main/src/sample/computeBoids/main.ts
const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;

core: mach.Core,
timer: mach.Timer,
compute_pipeline: *gpu.ComputePipeline,
render_pipeline: *gpu.RenderPipeline,
sprite_vertex_buffer: *gpu.Buffer,
particle_buffers: [2]*gpu.Buffer,
particle_bind_groups: [2]*gpu.BindGroup,
sim_param_buffer: *gpu.Buffer,
frame_counter: usize,

pub const App = @This();

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const num_particle = 1500;

var sim_params = [_]f32{
    0.04, // .delta_T
    0.1, // .rule_1_distance
    0.025, // .rule_2_distance
    0.025, // .rule_3_distance
    0.02, // .rule_1_scale
    0.05, // .rule_2_scale
    0.005, // .rule_3_scale
};

pub fn init(app: *App) !void {
    try app.core.init(gpa.allocator(), .{});

    const sprite_shader_module = app.core.device().createShaderModuleWGSL(
        "sprite.wgsl",
        @embedFile("sprite.wgsl"),
    );

    const update_sprite_shader_module = app.core.device().createShaderModuleWGSL(
        "updateSprites.wgsl",
        @embedFile("updateSprites.wgsl"),
    );

    const instanced_particles_attributes = [_]gpu.VertexAttribute{
        .{
            // instance position
            .shader_location = 0,
            .offset = 0,
            .format = .float32x2,
        },
        .{
            // instance velocity
            .shader_location = 1,
            .offset = 2 * 4,
            .format = .float32x2,
        },
    };

    const vertex_buffer_attributes = [_]gpu.VertexAttribute{
        .{
            // vertex positions
            .shader_location = 2,
            .offset = 0,
            .format = .float32x2,
        },
    };

    const render_pipeline = app.core.device().createRenderPipeline(&gpu.RenderPipeline.Descriptor{
        .vertex = gpu.VertexState.init(.{
            .module = sprite_shader_module,
            .entry_point = "vert_main",
            .buffers = &.{
                gpu.VertexBufferLayout.init(.{
                    // instanced particles buffer
                    .array_stride = 4 * 4,
                    .step_mode = .instance,
                    .attributes = &instanced_particles_attributes,
                }),
                gpu.VertexBufferLayout.init(.{
                    // vertex buffer
                    .array_stride = 2 * 4,
                    .step_mode = .vertex,
                    .attributes = &vertex_buffer_attributes,
                }),
            },
        }),
        .fragment = &gpu.FragmentState.init(.{
            .module = sprite_shader_module,
            .entry_point = "frag_main",
            .targets = &[_]gpu.ColorTargetState{.{
                .format = app.core.descriptor().format,
            }},
        }),
    });

    const compute_pipeline = app.core.device().createComputePipeline(&gpu.ComputePipeline.Descriptor{ .compute = gpu.ProgrammableStageDescriptor{
        .module = update_sprite_shader_module,
        .entry_point = "main",
    } });

    const vert_buffer_data = [_]f32{
        -0.01, -0.02, 0.01,
        -0.02, 0.0,   0.02,
    };

    const sprite_vertex_buffer = app.core.device().createBuffer(&gpu.Buffer.Descriptor{
        .label = "sprite_vertex_buffer",
        .usage = .{ .vertex = true },
        .mapped_at_creation = true,
        .size = vert_buffer_data.len * @sizeOf(f32),
    });
    var vertex_mapped = sprite_vertex_buffer.getMappedRange(f32, 0, vert_buffer_data.len);
    std.mem.copy(f32, vertex_mapped.?, vert_buffer_data[0..]);
    sprite_vertex_buffer.unmap();

    const sim_param_buffer = app.core.device().createBuffer(&gpu.Buffer.Descriptor{
        .label = "sim_param_buffer",
        .usage = .{ .uniform = true, .copy_dst = true },
        .size = sim_params.len * @sizeOf(f32),
    });
    app.core.device().getQueue().writeBuffer(sim_param_buffer, 0, sim_params[0..]);

    var initial_particle_data: [num_particle * 4]f32 = undefined;
    var rng = std.rand.DefaultPrng.init(0);
    const random = rng.random();
    var i: usize = 0;
    while (i < num_particle) : (i += 1) {
        initial_particle_data[4 * i + 0] = 2 * (random.float(f32) - 0.5);
        initial_particle_data[4 * i + 1] = 2 * (random.float(f32) - 0.5);
        initial_particle_data[4 * i + 2] = 2 * (random.float(f32) - 0.5) * 0.1;
        initial_particle_data[4 * i + 3] = 2 * (random.float(f32) - 0.5) * 0.1;
    }

    var particle_buffers: [2]*gpu.Buffer = undefined;
    var particle_bind_groups: [2]*gpu.BindGroup = undefined;
    i = 0;
    while (i < 2) : (i += 1) {
        particle_buffers[i] = app.core.device().createBuffer(&gpu.Buffer.Descriptor{
            .label = "particle_buffer",
            .mapped_at_creation = true,
            .usage = .{
                .vertex = true,
                .storage = true,
            },
            .size = initial_particle_data.len * @sizeOf(f32),
        });
        var mapped = particle_buffers[i].getMappedRange(f32, 0, initial_particle_data.len);
        std.mem.copy(f32, mapped.?, initial_particle_data[0..]);
        particle_buffers[i].unmap();
    }

    i = 0;
    while (i < 2) : (i += 1) {
        particle_bind_groups[i] = app.core.device().createBindGroup(&gpu.BindGroup.Descriptor.init(.{
            .layout = compute_pipeline.getBindGroupLayout(0),
            .entries = &.{
                gpu.BindGroup.Entry.buffer(0, sim_param_buffer, 0, sim_params.len * @sizeOf(f32)),
                gpu.BindGroup.Entry.buffer(1, particle_buffers[i], 0, initial_particle_data.len * @sizeOf(f32)),
                gpu.BindGroup.Entry.buffer(2, particle_buffers[(i + 1) % 2], 0, initial_particle_data.len * @sizeOf(f32)),
            },
        }));
    }

    app.* = .{
        .core = app.core,
        .timer = try mach.Timer.start(),
        .compute_pipeline = compute_pipeline,
        .render_pipeline = render_pipeline,
        .sprite_vertex_buffer = sprite_vertex_buffer,
        .particle_buffers = particle_buffers,
        .particle_bind_groups = particle_bind_groups,
        .sim_param_buffer = sim_param_buffer,
        .frame_counter = 0,
    };
}

pub fn deinit(app: *App) void {
    defer _ = gpa.deinit();
    defer app.core.deinit();
}

pub fn update(app: *App) !bool {
    const delta_time = app.timer.lap();

    var iter = app.core.pollEvents();
    while (iter.next()) |event| {
        if (event == .close) return true;
    }

    const back_buffer_view = app.core.swapChain().getCurrentTextureView();
    const color_attachment = gpu.RenderPassColorAttachment{
        .view = back_buffer_view,
        .clear_value = std.mem.zeroes(gpu.Color),
        .load_op = .clear,
        .store_op = .store,
    };

    const render_pass_descriptor = gpu.RenderPassDescriptor.init(.{
        .color_attachments = &.{
            color_attachment,
        },
    });

    sim_params[0] = @floatCast(f32, delta_time);
    app.core.device().getQueue().writeBuffer(app.sim_param_buffer, 0, sim_params[0..]);

    const command_encoder = app.core.device().createCommandEncoder(null);
    {
        const pass_encoder = command_encoder.beginComputePass(null);
        pass_encoder.setPipeline(app.compute_pipeline);
        pass_encoder.setBindGroup(0, app.particle_bind_groups[app.frame_counter % 2], null);
        pass_encoder.dispatchWorkgroups(@floatToInt(u32, @ceil(@as(f32, num_particle) / 64)), 1, 1);
        pass_encoder.end();
        pass_encoder.release();
    }
    {
        const pass_encoder = command_encoder.beginRenderPass(&render_pass_descriptor);
        pass_encoder.setPipeline(app.render_pipeline);
        pass_encoder.setVertexBuffer(0, app.particle_buffers[(app.frame_counter + 1) % 2], 0, num_particle * 4 * @sizeOf(f32));
        pass_encoder.setVertexBuffer(1, app.sprite_vertex_buffer, 0, 6 * @sizeOf(f32));
        pass_encoder.draw(3, num_particle, 0, 0);
        pass_encoder.end();
        pass_encoder.release();
    }

    app.frame_counter += 1;
    if (app.frame_counter % 60 == 0) {
        std.log.info("Frame {}", .{app.frame_counter});
    }

    var command = command_encoder.finish(null);
    command_encoder.release();
    app.core.device().getQueue().submit(&[_]*gpu.CommandBuffer{command});
    command.release();

    app.core.swapChain().present();
    back_buffer_view.release();

    return false;
}
