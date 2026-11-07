#include <metal_stdlib>
using namespace metal;

// The prototype's three.js shader (prototype/spatial/index.html), in Metal.
// data texture: R = front depth, G = front alpha, B = back depth (1 = near), A = focus (1 on the subject).

struct Uniforms {
    float4x4 mvp;
    float strength;
    float rise;    // 0…1, depth grows in from the top once it is known
    float time;
    float scan;    // analyzing: a band of light reads the flat photo top to bottom
    float reduced;
    float front;
};

struct Fragment {
    float4 position [[position]];
    float2 uv;
    float depth;   // the depth the triangle interpolates between its corners
};

constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
constexpr sampler mipClamp(filter::linear, mip_filter::linear, address::clamp_to_edge);
// how soft the background is: the mip level read behind the subject.
// ponytail: fixed; 1.8 hides LaMa's softness at 1280 pixels, tune if it looks too dreamy
constant float defocus = 1.8;
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
    out.depth = d;
    return out;
}

fragment float4 spatialFragment(Fragment in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                texture2d<float> image [[texture(0)]], texture2d<float> data [[texture(1)]]) {
    float a = 1.;
    float focus = 0.;   // the back layer is all background, so always soft
    if (u.front > .5) {
        float4 t = data.sample(linearClamp, in.uv);
        a = t.g;
        focus = t.a;
        if (a < .02) discard_fragment();
        // a triangle with one corner on the subject and one behind it is stretched across the jump; there the
        // interpolated depth sits between near and far and differs from the photo's own depth at this point.
        // Dropping those pixels shows the rebuilt back layer instead of streaks.
        if (abs(in.depth - t.r) > .08) discard_fragment();
    }
    // behind the subject, a smaller copy of the photo: a soft background, growing in with the depth
    float3 c = image.sample(mipClamp, in.uv, level((1. - focus) * defocus * u.rise)).rgb;
    if (u.scan > 0.) {
        float p = fract(u.time * .4) * 1.4 - .2;
        float offset = (in.uv.y - p) * 14.;
        float band = u.reduced > .5 ? .25 + .25 * sin(u.time * 2.) : exp(-offset * offset);
        c = mix(c, float3(dot(c, float3(.299, .587, .114))), .4 * u.scan);
        c += light * band * .45 * u.scan;
    }
    return float4(c, a);
}
