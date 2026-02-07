//
//  MPRShaders.metal
//  DicomVmac
//
//  GPU shaders for MPR and Volume Rendering.
//  Supports slice view, MIP, MinIP, AIP, and Volume Rendering with transfer functions.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Uniforms

struct MPRUniforms {
    float windowCenter;
    float windowWidth;
    float rescaleSlope;
    float rescaleIntercept;
    float zoomScale;
    float2 panOffset;
    float slicePosition;       // 0-1 position within the volume
    int plane;                 // 0=axial, 1=coronal, 2=sagittal, 3=projection
    float2 crosshairPosition;  // Crosshair position in texture coords
    int showCrosshair;         // 1 to show crosshair lines
    int renderMode;            // 0=slice, 1=MIP, 2=MinIP, 3=AIP, 4=VR
    int numSamples;            // Ray marching sample count
    float2 rotation;           // Rotation angles for 3D projection (azimuth, elevation)
    int vrPreset;              // VR transfer function preset
};

// MARK: - Vertex Data

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

// MARK: - Vertex Shader

vertex VertexOut mprVertexShader(uint vertexID [[vertex_id]],
                                 constant MPRUniforms& uniforms [[buffer(0)]]) {
    VertexOut out;

    // Apply zoom and pan to quad positions
    float2 pos = quadPositions[vertexID];
    pos = pos * uniforms.zoomScale + uniforms.panOffset;

    out.position = float4(pos, 0.0, 1.0);
    out.texCoord = quadTexCoords[vertexID];
    return out;
}

// MARK: - Helper Functions

// Sample and rescale from 3D texture
inline float sampleVolume(texture3d<ushort, access::sample> volume,
                          sampler volumeSampler,
                          float3 pos,
                          constant MPRUniforms& uniforms) {
    ushort rawValue = volume.sample(volumeSampler, pos).r;
    return float(rawValue) * uniforms.rescaleSlope + uniforms.rescaleIntercept;
}

// Apply window/level to HU value
inline float applyWindowLevel(float hu, constant MPRUniforms& uniforms) {
    float lower = uniforms.windowCenter - uniforms.windowWidth * 0.5;
    float upper = uniforms.windowCenter + uniforms.windowWidth * 0.5;
    return saturate((hu - lower) / (upper - lower));
}

// Get ray direction based on rotation angles
inline float3 getRayDirection(float2 texCoord, float2 rotation) {
    // Convert texture coords to centered coordinates
    float2 uv = texCoord * 2.0 - 1.0;

    // Base ray direction (front to back)
    float3 rayDir = float3(0.0, 0.0, 1.0);

    // Apply rotation (azimuth around Y, elevation around X)
    float cosA = cos(rotation.x);
    float sinA = sin(rotation.x);
    float cosE = cos(rotation.y);
    float sinE = sin(rotation.y);

    // Rotation matrix
    float3x3 rotY = float3x3(
        float3(cosA, 0, sinA),
        float3(0, 1, 0),
        float3(-sinA, 0, cosA)
    );
    float3x3 rotX = float3x3(
        float3(1, 0, 0),
        float3(0, cosE, -sinE),
        float3(0, sinE, cosE)
    );

    // Calculate ray origin on view plane
    float3 right = rotY * rotX * float3(1, 0, 0);
    float3 up = rotY * rotX * float3(0, 1, 0);
    float3 forward = rotY * rotX * float3(0, 0, 1);

    return normalize(forward);
}

// Get ray origin on view plane
inline float3 getRayOrigin(float2 texCoord, float2 rotation) {
    float2 uv = texCoord * 2.0 - 1.0;

    float cosA = cos(rotation.x);
    float sinA = sin(rotation.x);
    float cosE = cos(rotation.y);
    float sinE = sin(rotation.y);

    float3x3 rotY = float3x3(
        float3(cosA, 0, sinA),
        float3(0, 1, 0),
        float3(-sinA, 0, cosA)
    );
    float3x3 rotX = float3x3(
        float3(1, 0, 0),
        float3(0, cosE, -sinE),
        float3(0, sinE, cosE)
    );

    float3 right = rotY * rotX * float3(1, 0, 0);
    float3 up = rotY * rotX * float3(0, 1, 0);

    // Start at center of volume with offset based on screen position
    return float3(0.5, 0.5, 0.5) + right * uv.x * 0.5 + up * uv.y * 0.5 - getRayDirection(texCoord, rotation) * 0.866;
}

// VR Transfer function - maps HU to RGBA
inline float4 transferFunction(float hu, int preset) {
    float4 color = float4(0.0);

    if (preset == 0) {
        // Bone preset: emphasize high HU values
        if (hu > 300.0) {
            float t = saturate((hu - 300.0) / 1200.0);
            color = float4(1.0, 0.95, 0.8, t * 0.8);  // Yellow-white bone
        } else if (hu > 100.0) {
            float t = saturate((hu - 100.0) / 200.0);
            color = float4(0.8, 0.6, 0.4, t * 0.1);   // Faint soft tissue
        }
    } else if (preset == 1) {
        // Soft tissue preset
        if (hu > -100.0 && hu < 200.0) {
            float t = saturate((hu + 100.0) / 300.0);
            color = float4(0.9, 0.6, 0.5, t * 0.4);  // Pink/red tissue
        } else if (hu > 200.0 && hu < 400.0) {
            float t = saturate((hu - 200.0) / 200.0);
            color = float4(1.0, 0.9, 0.8, t * 0.3);  // Light bone
        }
    } else if (preset == 2) {
        // Lung preset: emphasize low HU values (air)
        if (hu < -400.0) {
            float t = saturate((-400.0 - hu) / 600.0);
            color = float4(0.4, 0.6, 0.9, t * 0.3);  // Blue air
        } else if (hu > -100.0 && hu < 100.0) {
            float t = saturate((hu + 100.0) / 200.0);
            color = float4(0.8, 0.5, 0.4, t * 0.2);  // Faint vessels/tissue
        }
    } else if (preset == 3) {
        // Angio preset: contrast-enhanced vessels
        if (hu > 100.0 && hu < 500.0) {
            float t = saturate((hu - 100.0) / 400.0);
            color = float4(1.0, 0.3, 0.2, t * 0.9);  // Bright red vessels
        } else if (hu > 500.0) {
            float t = saturate((hu - 500.0) / 500.0);
            color = float4(1.0, 0.95, 0.8, t * 0.5);  // Bone (dimmed)
        }
    }

    return color;
}

// MARK: - Slice Fragment Shader (existing)

fragment float4 mprFragmentShader(VertexOut in [[stage_in]],
                                  texture3d<ushort, access::sample> volume [[texture(0)]],
                                  constant MPRUniforms& uniforms [[buffer(0)]]) {
    constexpr sampler volumeSampler(
        coord::normalized,
        filter::linear,
        address::clamp_to_edge
    );

    // Calculate sample position based on plane type
    float3 samplePos;
    float2 texCoord = in.texCoord;

    if (uniforms.plane == 0) {
        // Axial: XY plane at Z = slicePosition
        samplePos = float3(texCoord.x, texCoord.y, uniforms.slicePosition);
    } else if (uniforms.plane == 1) {
        // Coronal: XZ plane at Y = slicePosition
        samplePos = float3(texCoord.x, uniforms.slicePosition, texCoord.y);
    } else {
        // Sagittal: YZ plane at X = slicePosition
        samplePos = float3(uniforms.slicePosition, texCoord.x, texCoord.y);
    }

    // Sample and apply window/level
    float hu = sampleVolume(volume, volumeSampler, samplePos, uniforms);
    float normalized = applyWindowLevel(hu, uniforms);
    float3 color = float3(normalized);

    // Draw crosshair if enabled
    if (uniforms.showCrosshair) {
        float2 crossPos = uniforms.crosshairPosition;
        float lineWidth = 0.002;

        if (abs(texCoord.y - crossPos.y) < lineWidth) {
            color = mix(color, float3(0.0, 1.0, 0.0), 0.7);
        }
        if (abs(texCoord.x - crossPos.x) < lineWidth) {
            color = mix(color, float3(0.0, 1.0, 0.0), 0.7);
        }
    }

    return float4(color, 1.0);
}

// MARK: - MIP Fragment Shader (Maximum Intensity Projection)

fragment float4 mipFragmentShader(VertexOut in [[stage_in]],
                                  texture3d<ushort, access::sample> volume [[texture(0)]],
                                  constant MPRUniforms& uniforms [[buffer(0)]]) {
    constexpr sampler volumeSampler(
        coord::normalized,
        filter::linear,
        address::clamp_to_edge
    );

    float2 texCoord = in.texCoord;
    int numSamples = max(uniforms.numSamples, 64);

    // Get ray direction and origin based on rotation
    float3 rayDir = getRayDirection(texCoord, uniforms.rotation);
    float3 rayOrigin = getRayOrigin(texCoord, uniforms.rotation);

    float maxHU = -10000.0;

    // March through volume
    for (int i = 0; i < numSamples; i++) {
        float t = float(i) / float(numSamples - 1);
        float3 samplePos = rayOrigin + rayDir * t * 1.732;  // sqrt(3) for diagonal

        // Check bounds
        if (all(samplePos >= 0.0) && all(samplePos <= 1.0)) {
            float hu = sampleVolume(volume, volumeSampler, samplePos, uniforms);
            maxHU = max(maxHU, hu);
        }
    }

    // Apply window/level to max value
    float normalized = applyWindowLevel(maxHU, uniforms);
    return float4(float3(normalized), 1.0);
}

// MARK: - MinIP Fragment Shader (Minimum Intensity Projection)

fragment float4 minipFragmentShader(VertexOut in [[stage_in]],
                                    texture3d<ushort, access::sample> volume [[texture(0)]],
                                    constant MPRUniforms& uniforms [[buffer(0)]]) {
    constexpr sampler volumeSampler(
        coord::normalized,
        filter::linear,
        address::clamp_to_edge
    );

    float2 texCoord = in.texCoord;
    int numSamples = max(uniforms.numSamples, 64);

    float3 rayDir = getRayDirection(texCoord, uniforms.rotation);
    float3 rayOrigin = getRayOrigin(texCoord, uniforms.rotation);

    float minHU = 10000.0;

    for (int i = 0; i < numSamples; i++) {
        float t = float(i) / float(numSamples - 1);
        float3 samplePos = rayOrigin + rayDir * t * 1.732;

        if (all(samplePos >= 0.0) && all(samplePos <= 1.0)) {
            float hu = sampleVolume(volume, volumeSampler, samplePos, uniforms);
            minHU = min(minHU, hu);
        }
    }

    float normalized = applyWindowLevel(minHU, uniforms);
    return float4(float3(normalized), 1.0);
}

// MARK: - AIP Fragment Shader (Average Intensity Projection)

fragment float4 aipFragmentShader(VertexOut in [[stage_in]],
                                  texture3d<ushort, access::sample> volume [[texture(0)]],
                                  constant MPRUniforms& uniforms [[buffer(0)]]) {
    constexpr sampler volumeSampler(
        coord::normalized,
        filter::linear,
        address::clamp_to_edge
    );

    float2 texCoord = in.texCoord;
    int numSamples = max(uniforms.numSamples, 64);

    float3 rayDir = getRayDirection(texCoord, uniforms.rotation);
    float3 rayOrigin = getRayOrigin(texCoord, uniforms.rotation);

    float sumHU = 0.0;
    int validSamples = 0;

    for (int i = 0; i < numSamples; i++) {
        float t = float(i) / float(numSamples - 1);
        float3 samplePos = rayOrigin + rayDir * t * 1.732;

        if (all(samplePos >= 0.0) && all(samplePos <= 1.0)) {
            float hu = sampleVolume(volume, volumeSampler, samplePos, uniforms);
            sumHU += hu;
            validSamples++;
        }
    }

    float avgHU = validSamples > 0 ? sumHU / float(validSamples) : 0.0;
    float normalized = applyWindowLevel(avgHU, uniforms);
    return float4(float3(normalized), 1.0);
}

// MARK: - VR Fragment Shader (Volume Rendering)

fragment float4 vrFragmentShader(VertexOut in [[stage_in]],
                                 texture3d<ushort, access::sample> volume [[texture(0)]],
                                 constant MPRUniforms& uniforms [[buffer(0)]]) {
    constexpr sampler volumeSampler(
        coord::normalized,
        filter::linear,
        address::clamp_to_edge
    );

    float2 texCoord = in.texCoord;
    int numSamples = max(uniforms.numSamples, 64);

    float3 rayDir = getRayDirection(texCoord, uniforms.rotation);
    float3 rayOrigin = getRayOrigin(texCoord, uniforms.rotation);

    // Front-to-back compositing
    float4 accumulated = float4(0.0);

    for (int i = 0; i < numSamples && accumulated.a < 0.95; i++) {
        float t = float(i) / float(numSamples - 1);
        float3 samplePos = rayOrigin + rayDir * t * 1.732;

        if (all(samplePos >= 0.0) && all(samplePos <= 1.0)) {
            float hu = sampleVolume(volume, volumeSampler, samplePos, uniforms);
            float4 sampleColor = transferFunction(hu, uniforms.vrPreset);

            // Front-to-back compositing
            accumulated.rgb += (1.0 - accumulated.a) * sampleColor.a * sampleColor.rgb;
            accumulated.a += (1.0 - accumulated.a) * sampleColor.a;
        }
    }

    // Add background for transparency
    float3 bgColor = float3(0.0);
    accumulated.rgb = accumulated.rgb + (1.0 - accumulated.a) * bgColor;
    accumulated.a = 1.0;

    return accumulated;
}

// MARK: - Crosshair-only Shader (for overlay rendering)

struct CrosshairUniforms {
    float2 position;
    float4 color;
    float lineWidth;
};

fragment float4 crosshairFragmentShader(VertexOut in [[stage_in]],
                                        constant CrosshairUniforms& uniforms [[buffer(0)]]) {
    float2 pos = in.texCoord * 2.0 - 1.0;

    float distX = abs(pos.x - uniforms.position.x);
    float distY = abs(pos.y - uniforms.position.y);

    if (distX < uniforms.lineWidth || distY < uniforms.lineWidth) {
        return uniforms.color;
    }

    discard_fragment();
    return float4(0.0);
}
