#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

constant const int kAxisMaxViewCount = 2;

struct AxisVertex {
    float3 position [[attribute(0)]];
    float3 color [[attribute(1)]];
};

struct AxisUniforms {
    simd::float4x4 projectionMatrix;
    simd::float4x4 viewMatrix;
};

struct AxisUniformsArray {
    AxisUniforms uniforms[kAxisMaxViewCount];
};

struct AxisVaryings {
    float4 position [[position]];
    float3 color;
};

vertex AxisVaryings axisVertex(AxisVertex in [[stage_in]],
                               ushort amp_id [[amplification_id]],
                               constant AxisUniformsArray & uniformsArray [[ buffer(1) ]]) {
    AxisVaryings out;
    AxisUniforms u = uniformsArray.uniforms[min(int(amp_id), kAxisMaxViewCount - 1)];
    out.position = u.projectionMatrix * u.viewMatrix * float4(in.position, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 axisFragment(AxisVaryings in [[stage_in]]) {
    return float4(in.color, 1.0);
}

