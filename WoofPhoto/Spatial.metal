#include <metal_stdlib>
using namespace metal;

// The prototype's three.js shader (prototype/spatial/index.html), in Metal.
// data texture: R = front depth, G = front alpha, B = back depth (1 = near).

struct Uniforms {
    float4x4 mvp;
    float strength;
    float rise;    // 0…1, depth grows in from the top once it is known
    float time;
    float scan;    // analyzing: a band of light reads the flat photo top to bottom
    float build;   // rebuilding: the area LaMa repaints (mask) shimmers
    float reduced;
    float front;
};

struct Fragment {
    float4 position [[position]];
    float2 uv;
};

constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
constant float3 light = float3(.55, .82, 1.);

vertex Fragment spatialVertex(uint id [[vertex_id]], const device float2 *uvs [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]], texture2d<float> data [[texture(0)]]) {
    float2 uv = uvs[id];
    float4 t = data.sample(linearClamp, uv, level(0));
    float d = u.front > .5 ? t.r : t.b;
    float g = smoothstep(0., 1., clamp((u.rise * 1.4 - uv.y) / .4, 0., 1.));
    Fragment out;
    out.position = u.mvp * float4(uv.x - .5, .5 - uv.y, d * u.strength * g, 1.);
    out.uv = uv;
    return out;
}

fragment float4 spatialFragment(Fragment in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                texture2d<float> image [[texture(0)]], texture2d<float> data [[texture(1)]],
                                texture2d<float> mask [[texture(2)]]) {
    float a = 1.;
    if (u.front > .5) {
        a = data.sample(linearClamp, in.uv).g;
        if (a < .02) discard_fragment();
    }
    float3 c = image.sample(linearClamp, in.uv).rgb;
    if (u.scan > 0.) {
        float p = fract(u.time * .4) * 1.4 - .2;
        float offset = (in.uv.y - p) * 14.;
        float band = u.reduced > .5 ? .25 + .25 * sin(u.time * 2.) : exp(-offset * offset);
        c = mix(c, float3(dot(c, float3(.299, .587, .114))), .4 * u.scan);
        c += light * band * .45 * u.scan;
    }
    if (u.build > 0.) {
        float m = mask.sample(linearClamp, in.uv).r;
        float s = u.reduced > .5 ? .5 : .5 + .5 * sin((in.uv.x + 1. - in.uv.y) * 40. - u.time * 3.);
        c += light * m * u.build * (.12 + .3 * s);
    }
    return float4(c, a);
}
