//
//  Shaders.metal
//  DicomVmac
//
//  GPU shaders for DICOM image rendering.
//  The fragment shader applies Window/Level transformation in real-time.
//  Uniform buffer provides dynamic WL/WW, rescale, zoom, and pan parameters.
//

#include <metal_stdlib>
using namespace metal;

struct DicomUniforms {
    float windowCenter;
    float windowWidth;
    float rescaleSlope;
    float rescaleIntercept;
    float zoomScale;
    float2 panOffset;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Full-screen quad vertices (2 triangles)
constant float2 quadPositions[6] = {
    float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
    float2(-1.0,  1.0), float2( 1.0, -1.0), float2( 1.0,  1.0)
};

constant float2 quadTexCoords[6] = {
    float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0),
    float2(0.0, 0.0), float2(1.0, 1.0), float2(1.0, 0.0)
};

vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                              constant DicomUniforms& uniforms [[buffer(0)]]) {
    VertexOut out;

    // Apply zoom and pan to quad positions
    float2 pos = quadPositions[vertexID];
    pos = pos * uniforms.zoomScale + uniforms.panOffset;

    out.position = float4(pos, 0.0, 1.0);
    out.texCoord = quadTexCoords[vertexID];
    return out;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<ushort, access::sample> dicomTexture [[texture(0)]],
                               constant DicomUniforms& uniforms [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::nearest, min_filter::nearest);

    ushort rawValue = dicomTexture.sample(textureSampler, in.texCoord).r;

    // Apply rescale: HU = storedValue * slope + intercept
    float hu = float(rawValue) * uniforms.rescaleSlope + uniforms.rescaleIntercept;

    // Apply window/level
    float lower = uniforms.windowCenter - uniforms.windowWidth * 0.5;
    float upper = uniforms.windowCenter + uniforms.windowWidth * 0.5;
    float normalized = saturate((hu - lower) / (upper - lower));

    return float4(normalized, normalized, normalized, 1.0);
}

// MARK: - Annotation Shaders

struct AnnotationUniforms {
    float zoomScale;
    float2 panOffset;
    float4 color;
};

struct AnnotationVertexIn {
    float2 position [[attribute(0)]];  // texture coords (0-1)
};

struct AnnotationVertexOut {
    float4 position [[position]];
    float4 color;
};

// Convert texture coordinate (0-1) to NDC with zoom/pan transform
vertex AnnotationVertexOut annotationVertexShader(
    AnnotationVertexIn in [[stage_in]],
    constant AnnotationUniforms& uniforms [[buffer(0)]]
) {
    AnnotationVertexOut out;

    // Convert texture coord (0-1) to NDC (-1 to 1)
    float2 ndc = in.position * 2.0 - 1.0;
    ndc.y = -ndc.y;  // Flip Y to match Metal coordinate system

    // Apply same zoom/pan transform as the DICOM image
    ndc = ndc * uniforms.zoomScale + uniforms.panOffset;

    out.position = float4(ndc, 0.0, 1.0);
    out.color = uniforms.color;
    return out;
}

fragment float4 annotationFragmentShader(AnnotationVertexOut in [[stage_in]]) {
    return in.color;
}
