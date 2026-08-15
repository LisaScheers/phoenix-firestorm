#include <metal_stdlib>

using namespace metal;

struct BootstrapVertex
{
    float4 position [[position]];
    half4 color;
};

vertex BootstrapVertex firestorm_bootstrap_vertex(uint vertex_id [[vertex_id]])
{
    constexpr float2 positions[] =
    {
        float2( 0.0f,  0.70f),
        float2(-0.62f, -0.55f),
        float2( 0.62f, -0.55f),
    };

    constexpr half4 colors[] =
    {
        half4(1.0h, 0.35h, 0.12h, 1.0h),
        half4(0.18h, 0.72h, 1.0h, 1.0h),
        half4(0.72h, 0.32h, 1.0h, 1.0h),
    };

    BootstrapVertex output;
    output.position = float4(positions[vertex_id], 0.0f, 1.0f);
    output.color = colors[vertex_id];
    return output;
}

fragment half4 firestorm_bootstrap_fragment(BootstrapVertex input [[stage_in]])
{
    return input.color;
}

struct OffscreenVertex
{
    float4 position [[position]];
};

vertex OffscreenVertex firestorm_offscreen_orientation_vertex(
    uint vertex_id [[vertex_id]])
{
    constexpr float2 positions[] =
    {
        float2(-1.0f, -1.0f),
        float2( 3.0f, -1.0f),
        float2(-1.0f,  3.0f),
    };

    OffscreenVertex output;
    output.position = float4(positions[vertex_id], 0.0f, 1.0f);
    return output;
}

fragment half4 firestorm_offscreen_orientation_fragment(
    OffscreenVertex input [[stage_in]])
{
    const uint2 pixel = uint2(input.position.xy);
    if (pixel.y == 0)
    {
        return pixel.x == 0
            ? half4(1.0h, 0.0h, 0.0h, 1.0h)
            : half4(0.0h, 1.0h, 0.0h, 1.0h);
    }

    return pixel.x == 0
        ? half4(0.0h, 0.0h, 1.0h, 1.0h)
        : half4(1.0h, 1.0h, 1.0h, 1.0h);
}

kernel void firestorm_sampler_test(
    texture2d<half, access::sample> source [[texture(0)]],
    texture2d<half, access::write> output [[texture(1)]],
    sampler repeat_sampler [[sampler(0)]],
    sampler clamp_sampler [[sampler(1)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= 2 || position.y != 0)
    {
        return;
    }

    constexpr float2 outside_left(-0.125f, 0.5f);
    const half4 color = position.x == 0
        ? source.sample(repeat_sampler, outside_left)
        : source.sample(clamp_sampler, outside_left);
    output.write(color, position);
}

struct DepthRasterDraw
{
    float depth;
    uint reverse_winding;
    uint color_index;
    uint unused;
};

struct DepthRasterVertex
{
    float4 position [[position]];
    half4 color;
};

vertex DepthRasterVertex firestorm_depth_raster_vertex(
    uint vertex_id [[vertex_id]],
    constant DepthRasterDraw& draw [[buffer(0)]])
{
    constexpr float2 positions[] =
    {
        float2(-1.0f, -1.0f),
        float2(-1.0f,  3.0f),
        float2( 3.0f, -1.0f),
    };
    constexpr half4 colors[] =
    {
        half4(0.0h, 1.0h, 0.0h, 1.0h),
        half4(1.0h, 0.0h, 0.0h, 1.0h),
        half4(0.0h, 0.0h, 1.0h, 1.0h),
        half4(1.0h, 1.0h, 0.0h, 1.0h),
    };

    uint position_index = vertex_id;
    if (draw.reverse_winding != 0 && vertex_id != 0)
    {
        position_index = 3 - vertex_id;
    }

    DepthRasterVertex output;
    output.position = float4(positions[position_index], draw.depth, 1.0f);
    output.color = colors[draw.color_index];
    return output;
}

fragment half4 firestorm_depth_raster_fragment(
    DepthRasterVertex input [[stage_in]])
{
    return input.color;
}

struct BlendPipelineVertex
{
    float4 position [[position]];
};

vertex BlendPipelineVertex firestorm_blend_pipeline_vertex(
    uint vertex_id [[vertex_id]])
{
    constexpr float2 positions[] =
    {
        float2(-1.0f, -1.0f),
        float2( 3.0f, -1.0f),
        float2(-1.0f,  3.0f),
    };

    BlendPipelineVertex output;
    output.position = float4(positions[vertex_id], 0.0f, 1.0f);
    return output;
}

fragment float4 firestorm_blend_pipeline_fragment(
    constant uint4& color_bytes [[buffer(0)]])
{
    return float4(color_bytes) / 255.0f;
}

struct RenderPassDraw
{
    float depth;
    float3 unused;
};

struct RenderPassVertex
{
    float4 position [[position]];
};

vertex RenderPassVertex firestorm_render_pass_vertex(
    uint vertex_id [[vertex_id]],
    constant RenderPassDraw& draw [[buffer(0)]])
{
    constexpr float2 positions[] =
    {
        float2(-1.0f, -1.0f),
        float2(-1.0f,  3.0f),
        float2( 3.0f, -1.0f),
    };

    RenderPassVertex output;
    output.position = float4(positions[vertex_id], draw.depth, 1.0f);
    return output;
}

fragment half4 firestorm_render_pass_fragment()
{
    return half4(0.0h, 1.0h, 0.0h, 1.0h);
}

struct ColorGammaVertex
{
    float4 position [[position]];
};

vertex ColorGammaVertex firestorm_color_gamma_vertex(
    uint vertex_id [[vertex_id]])
{
    constexpr float2 positions[] =
    {
        float2(-1.0f, -1.0f),
        float2( 3.0f, -1.0f),
        float2(-1.0f,  3.0f),
    };

    ColorGammaVertex output;
    output.position = float4(positions[vertex_id], 0.0f, 1.0f);
    return output;
}

fragment float4 firestorm_color_gamma_constant_fragment()
{
    return float4(17.0f, 13.0f, 7.0f, 191.0f) / 255.0f;
}

fragment float4 firestorm_color_gamma_copy_fragment(
    texture2d<float, access::sample> source [[texture(0)]])
{
    constexpr sampler nearest_sampler(
        coord::normalized,
        address::clamp_to_edge,
        filter::nearest);
    return source.sample(nearest_sampler, float2(0.5f));
}

fragment float4 firestorm_color_gamma_final_fragment(
    texture2d<float, access::sample> source [[texture(0)]])
{
    constexpr sampler nearest_sampler(
        coord::normalized,
        address::clamp_to_edge,
        filter::nearest);
    const float4 linear = source.sample(nearest_sampler, float2(0.5f));
    const float3 linear_rgb = clamp(linear.rgb, 0.0f, 1.0f);
    const float3 encoded = select(
        12.92f * linear_rgb,
        1.055f * powr(linear_rgb, float3(1.0f / 2.4f)) - 0.055f,
        linear_rgb > 0.0031308f);
    return float4(encoded, linear.a);
}

struct MrtVertex
{
    float4 position [[position]];
};

vertex MrtVertex firestorm_mrt_vertex(
    uint vertex_id [[vertex_id]],
    constant float& depth [[buffer(0)]])
{
    constexpr float2 positions[] =
    {
        float2(-1.0f, -1.0f),
        float2(-1.0f,  3.0f),
        float2( 3.0f, -1.0f),
    };

    MrtVertex output;
    output.position = float4(positions[vertex_id], depth, 1.0f);
    return output;
}

struct MrtColors
{
    float4 color0 [[color(0)]];
    float4 color1 [[color(1)]];
    float4 color2 [[color(2)]];
    float4 color3 [[color(3)]];
};

fragment MrtColors firestorm_mrt_fragment()
{
    MrtColors output;
    output.color0 = float4(1.0f, 0.0f, 0.0f, 1.0f);
    output.color1 = float4(0.0f, 1.0f, 0.0f, 1.0f);
    output.color2 = float4(1.0f, 0.5f, 1.0f, 0.25f);
    output.color3 = float4(0.75f, 1.0f, 0.5f, 0.25f);
    return output;
}

fragment void firestorm_mrt_depth_fragment()
{
}
