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
