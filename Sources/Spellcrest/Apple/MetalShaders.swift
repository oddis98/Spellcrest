#if canImport(Metal)
// The engine's shaders in Metal, compiled at runtime as the GPU is made (`MetalGPU`), and a game's own made whole.

// Compiled at runtime, so building games doesn't need the offline Metal toolchain. What the engine's shaders and a
// game's own share: the structs, noise, the dither, and reading the scene's light. Each line it adds to the engine's
// library is compiled as a game starts, so keep it small.
let shaderCommon = """
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float4 position [[position]]; float2 uv; float4 color [[flat]]; float4 effects [[flat]]; float4 more [[flat]];
    float3 shade [[flat]]; // for a standing quad, the share of the light at its feet that gets through the shadows (litVertex)
    float4 stand [[flat]]; // for one standing in an isometric picture, its footprint's front edges and its height (Screen.stand)
};

// As Screen.queue writes them: x, y in the pass's pixels (y down) and u, v texture coords; the color to multiply by;
// then what the fragments make of it: for a sprite, how far to mix toward white (a flash), how much of a dissolve's
// pattern to keep, how it's lit and whether it glows; its feet in world pixels and its frame's place in the texture; and
// in an isometric picture, where it stands.
struct Corner { float4 xyuv; float4 color; float4 effects; float4 more; float4 stand; };

// How the canvas lies over the world, and the light maps under it (Screen.view).
struct View {
    float scale;    // the canvas's pixels to each of the game's
    float clouds;   // 0 none, 1 dithered, 2 smooth, read between the game's pixels
    float fog;      // 1: its thickness read between the game's pixels
    float vignette; // 1: the open map's alpha is a vignette
    float2 offset;  // the world pixel at the view's top left: the camera, shaken
    float2 origin;  // the world pixel at the light maps' first texel
    float2 size;    // the light maps' size in texels
    float2 canvas;  // the game's size in pixels
    float4 ambient; // the daylight's color
};

// What a game's shader is given besides its pixel: the scene's time in seconds, the canvas's size in the game's pixels,
// and the numbers the game gave it, values[0] to values[15] (Shader in Swift).
struct Values {
    float time;
    float unused;
    float2 size;
    float numbers[16];
    float operator[](int i) const { return numbers[clamp(i, 0, 15)]; }
};

// The picture drawn so far, for a layer shader: layer.sample(position) is its color there, in the game's pixels.
struct Layer {
    texture2d<float> picture;
    float scale;
    half4 sample(float2 position) const {
        constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
        return half4(picture.sample(nearest, position * scale / float2(picture.get_width(), picture.get_height())));
    }
};

// A 4x4 ordered dither: the order a dissolve's pixels go in, and the steps of a dithered edge.
constant float bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};

// Where a pixel comes in the 4x4 pattern, from 0 to 15/16.
float order(float2 pixel) { int2 cell = int2(floor(pixel)) & 3; return bayer[cell.y * 4 + cell.x] / 16; }

// The same in the middle of each step, for dithering: floor(shade * steps + dither(pixel)) / steps.
float dither(float2 pixel) { return order(pixel) + 1.0 / 32; }

float luma(float3 rgb) { return dot(rgb, float3(0.299, 0.587, 0.114)); }

float hash(float2 p) {
    float3 q = fract(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// Smooth value noise from 0 to 1, changing about once a unit.
float noise(float2 p) {
    float2 i = floor(p), f = fract(p), u = f * f * (3 - 2 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

// Four octaves of noise, from 0 to 1: clouds, fog, smoke.
float fbm(float2 p) {
    float sum = 0, amplitude = 0.5;
    for (int i = 0; i < 4; i++) {
        sum += amplitude * noise(p);
        p = p * 2.02 + float2(17.3, 9.1);
        amplitude *= 0.5;
    }
    return sum / 0.9375;
}

// A light map at a world pixel: the texel the pixel's in, so each of the game's pixels is lit as a whole, as its art is,
// sharp, where reading between them blurred the light's edges over a pixel.
float4 at(texture2d<float> map, float2 world, constant View &view) {
    return map.read(uint2(clamp(world - view.origin, float2(0), view.size - 1)));
}

// A map at a world pixel between the texels around it, for what's smooth: soft clouds and fog.
float4 between(texture2d<float> map, float2 world, constant View &view) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    return map.sample(linear, (world - view.origin) / view.size, level(0)); // a level of its own, so a vertex function could too
}

// How much daylight the clouds leave at a world pixel, from their own map: 1 without clouds.
float cloudy(texture2d<float> clouds, float2 world, constant View &view) {
    if (view.clouds < 0.5) return 1;
    return (view.clouds > 1.5 ? between(clouds, world, view) : at(clouds, world, view)).r;
}

// A color in a light: multiplied by it, and past daylight, 1, going toward the light's own white; its alpha drains it
// toward gray.
float3 shine(float3 rgb, float4 light) {
    float3 l = max(light.rgb, float3(0));
    float peak = max(l.r, max(l.g, l.b));
    rgb = mix(rgb * l, l / max(peak, 1.0), saturate((peak - 1) * 0.55));
    return mix(rgb, float3(luma(rgb)), saturate(light.a));
}

// Where on an isometric floor a pixel standing at `world`, in the picture, is lit from: under the point where the view's
// ray through it meets its box (`stand`: its footprint's front edges, x1 and y1, and its height), a world pixel out from
// the face it meets, so each face is lit from its own side; and how far up that point is. The ray's points are the
// floor's x + y = u, at x = (u + world.x) / 2, y = (u - world.x) / 2 and a height of u / 2 - world.y, and the box's
// nearest is where u first meets a front face or its top, never under the floor.
float3 underfoot(float2 world, float4 stand) {
    float right = 2 * stand.x - world.x, left = 2 * stand.y + world.x, top = 2 * world.y + 2 * stand.z;
    float u = max(min(min(right, left), top), 2 * world.y);
    float2 under = float2(world.x, u / 2);
    if (u > 2 * world.y && u < top) under += right <= left ? float2(1, 0.5) : float2(-1, 0.5);
    return float3(under, u / 2 - world.y);
}

// How much of the light past the daylight reaches a pixel `height` pixels above an isometric floor: all of it at its
// foot, half 64 pixels up, as a lamp lights a wall's foot more than its top.
float fade(float height) { return 1 / (1 + max(height, 0.0) / 64); }

// A canvas pixel's color as the scene's light maps light it, as `mode` says (Screen.Lighting): 0 not at all; 1 by its
// pixel's light; 2 by its pixel's without shadows; 3 standing, by that times `shade`, the share of the light at its
// feet that gets through the shadows; 4 by daylight alone; 5 raised, by the light on an isometric floor under it, what
// lights it past the daylight fading as it rises (`stand`). The shadowed map's alpha is how gray, the open one's the
// vignette. The clouds have a map of their own, so they can be soft while the light is sharp: the daylight they take,
// the ambient darkened by the vignette times their shade, comes off the light here, and the cap at daylight left room
// for it (`capFragment`).
float3 raised(float3 rgb, float2 pixel, float4 stand, constant View &view, texture2d<float> shadowed, texture2d<float> open,
              texture2d<float> clouds) {
    float3 under = underfoot(pixel / view.scale + view.offset, stand);
    float4 here = at(shadowed, under.xy, view);
    float left = cloudy(clouds, under.xy, view);
    float4 sky = at(open, under.xy, view);
    float3 taken = view.ambient.rgb * sky.a * (1 - left), daylight = view.ambient.rgb * sky.a * left;
    return shine(rgb, float4(mix(daylight, here.rgb - taken, fade(under.z)), here.a));
}

float3 lit(float3 rgb, float mode, float3 shade, float2 pixel, constant View &view, texture2d<float> shadowed, texture2d<float> open,
           texture2d<float> clouds, float4 stand = float4(0)) {
    if (mode < 0.5) return rgb;
    if (mode > 4.5) return raised(rgb, pixel, stand, view, shadowed, open, clouds);
    float2 world = pixel / view.scale + view.offset;
    float4 here = at(shadowed, world, view);
    float left = cloudy(clouds, world, view);
    float4 sky = mode > 1.5 || (left < 1 && view.vignette > 0.5) ? at(open, world, view) : float4(1);
    float3 taken = view.ambient.rgb * sky.a * (1 - left);
    if (mode < 1.5) return shine(rgb, float4(here.rgb - taken, here.a));
    if (mode > 3.5) return shine(rgb, float4(view.ambient.rgb * sky.a * left, here.a));
    return shine(rgb, float4((sky.rgb - taken) * (mode > 2.5 ? shade : float3(1)), here.a));
}

Vertex corner(uint i, constant Corner *v, constant float2 &size) {
    float2 p = v[i].xyuv.xy / size * 2 - 1;
    return { float4(p.x, -p.y, 0, 1), v[i].xyuv.zw, v[i].color, v[i].effects, v[i].more, float3(1), v[i].stand };
}

vertex Vertex spriteVertex(uint i [[vertex_id]], constant Corner *v [[buffer(0)]], constant float2 &size [[buffer(1)]]) { return corner(i, v, size); }

// The world's quads on the canvas: a standing one's share of the light at its feet (more.xy) that gets through the
// shadows, read once a corner rather than at each of its pixels.
vertex Vertex litVertex(uint i [[vertex_id]], constant Corner *v [[buffer(0)]], constant float2 &size [[buffer(1)]], constant View &view [[buffer(2)]],
                        texture2d<float> shadowed [[texture(1)]], texture2d<float> open [[texture(2)]]) {
    Vertex out = corner(i, v, size);
    if (v[i].effects.z > 2.5 && v[i].effects.z < 3.5) {
        out.shade = saturate(at(shadowed, v[i].more.xy, view).rgb / max(at(open, v[i].more.xy, view).rgb, float3(0.0001)));
    }
    return out;
}

"""

// The engine's own fragments, for the canvas and the screen.
let shaderEngine = """
// A sprite, a tile, text or a fill: its texture's pixel times its color, mixed toward white by a flash, dropped in a
// dissolve's pattern but for the share to keep, and lit as it says.
fragment float4 spriteFragment(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> shadowed [[texture(1)]],
                               texture2d<float> open [[texture(2)]], texture2d<float> clouds [[texture(3)]], texture2d<float> direction [[texture(4)]],
                               texture2d<float> normals [[texture(5)]], constant View &view [[buffer(0)]]) {
    if (order(in.position.xy / view.scale) >= in.effects.y) discard_fragment(); // the game's pixels, at any scale
    constexpr sampler nearest(filter::nearest);
    float4 c = t.sample(nearest, in.uv) * in.color;
    float3 rgb = mix(c.rgb, float3(1), saturate(in.effects.x));
    float3 out = lit(rgb, in.effects.z, in.shade, in.position.xy, view, shadowed, open, clouds, in.stand);
    float flip = dfdx(in.uv.x) < 0 ? -1 : 1; // mirrored, its texture's left is the screen's right
    float2 pixel = in.position.xy; // standing in an isometric picture, the way to the light is the floor's under it, as the pixel it's drawn at
    if (in.effects.z > 4.5) pixel = (underfoot(pixel / view.scale + view.offset, in.stand).xy - view.offset) * view.scale;
    if (in.effects.w > 1.5) out = shaped(out, in.effects.w < 2.5, in.uv, flip, in.more.zw, pixel, t, normals, direction, view); // 2 normal map, 3 rim
    return float4(out, c.a);
}

// A sprite that glows, added to what's under it and unlit: fire, magic, sparks.
fragment float4 glowFragment(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]], constant View &view [[buffer(0)]]) {
    if (order(in.position.xy / view.scale) >= in.effects.y) discard_fragment();
    constexpr sampler nearest(filter::nearest);
    float4 c = t.sample(nearest, in.uv) * in.color;
    return float4(mix(c.rgb, float3(1), saturate(in.effects.x)) * c.a, c.a);
}

// The canvas on the screen: at its size there pixel for pixel, or scaled the last little way, which nearest-neighbor
// would do by making some of the game's pixels a screen pixel wider than the rest.
fragment float4 smoothFragment(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler linear(filter::linear);
    return t.sample(linear, in.uv);
}

// A backdrop or an overhang over the view: its image from effects.xy in the view's pixels, each row swayed up to
// effects.z pixels by the time, effects.w; repeated across if more.x, down if more.y; lit as more.z says.
fragment float4 parallaxFragment(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> shadowed [[texture(1)]],
                                 texture2d<float> open [[texture(2)]], texture2d<float> clouds [[texture(3)]], constant View &view [[buffer(0)]]) {
    float2 size = float2(t.get_width(), t.get_height());
    float2 p = in.position.xy / view.scale - in.effects.xy;
    p.x -= sin(in.effects.w * 1.4 + floor(p.y) * 0.11) * in.effects.z;
    if (in.more.x > 0.5) p.x -= floor(p.x / size.x) * size.x; else if (p.x < 0 || p.x >= size.x) discard_fragment();
    if (in.more.y > 0.5) p.y -= floor(p.y / size.y) * size.y; else if (p.y < 0 || p.y >= size.y) discard_fragment();
    float4 c = t.read(uint2(min(p, size - 1)));
    if (c.a == 0) discard_fragment();
    return float4(lit(c.rgb, in.more.z, float3(1), in.position.xy, view, shadowed, open, clouds), c.a);
}

// Fog over the world: its color, as thick as its map (texture 0) says at each world pixel, or between them if it's
// smooth, lit as the ground is.
fragment float4 fogFragment(Vertex in [[stage_in]], texture2d<float> fog [[texture(0)]], texture2d<float> shadowed [[texture(1)]],
                            texture2d<float> open [[texture(2)]], texture2d<float> clouds [[texture(3)]], constant View &view [[buffer(0)]]) {
    float2 world = in.position.xy / view.scale + view.offset;
    float thick = (view.fog > 0.5 ? between(fog, world, view) : at(fog, world, view)).r;
    if (thick <= 0) discard_fragment();
    return float4(lit(in.color.rgb, 1, float3(1), in.position.xy, view, shadowed, open, clouds), thick);
}

"""

// How a lit sprite or tile turns toward its light, before the engine's fragments that use it. The direction map
// (texture 4) holds, at each world pixel, the way to the lights, weighted by how much of each gets there (rg), and how
// much does (b). A quad shaped by its normal map (texture 5) is lit by it, the light a little above the ground; one
// with a rim brightens the edge pixels facing it, its neighbors read within its frame (`frame`, its size in texels), so
// the next frame in its sheet doesn't count. A mirrored sprite (`flip`) is turned back.
let shapingShaders = """
float3 shaped(float3 out, bool mapped, float2 uv, float flip, float2 frame, float2 pixel, texture2d<float> t, texture2d<float> normals,
              texture2d<float> direction, constant View &view) {
    float4 d = at(direction, pixel / view.scale + view.offset, view);
    if (d.b < 0.002) return out;
    float2 toward = d.rg / d.b; // as long as 1 when one light lights it, shorter where lights from all round cancel
    float reach = saturate(length(toward));
    if (reach < 0.001) return out;
    float factor = 1;
    if (mapped) {
        constexpr sampler nearest(filter::nearest);
        float3 n = normals.sample(nearest, uv).xyz * 2 - 1;
        n.x *= flip;
        float3 l = normalize(float3(toward, 0.55)); // the light a little above the ground
        factor += 1.6 * (dot(normalize(n), l) - l.z) * reach;
    } else {
        int2 p = int2(floor(uv * float2(t.get_width(), t.get_height()))), size = max(int2(frame), int2(1)), at = p % size;
        float left = at.x > 0 ? t.read(uint2(p - int2(1, 0))).a : 0, right = at.x < size.x - 1 ? t.read(uint2(p + int2(1, 0))).a : 0;
        float up = at.y > 0 ? t.read(uint2(p - int2(0, 1))).a : 0, down = at.y < size.y - 1 ? t.read(uint2(p + int2(0, 1))).a : 0;
        float2 outward = float2((left - right) * flip, up - down); // toward the empty side: the sprite's edge
        if (dot(outward, outward) > 0.01) factor += 0.85 * saturate(dot(normalize(outward), normalize(toward))) * reach;
    }
    return out * max(factor, 0.25);
}

"""

// The light maps' shaders, drawn a texel for each world pixel the view shows: in them, in.position.xy is a texel's
// middle, and the texel's world pixel is its floor plus `view.origin`.
let lightShaders = """
struct Maps { float4 shadowed [[color(0)]]; float4 open [[color(1)]]; };
struct ShapedMaps { float4 shadowed [[color(0)]]; float4 open [[color(1)]]; float4 direction [[color(2)]]; };

// Whether light gets to the texel at `from` from its middle, `to`, both in the mask's texels, without going through
// what's opaque. It leaves out the opaque area it starts in, so a wall lights its own face, and one that reaches the
// light, so a lantern on a post still lights.
float through(texture2d<float> mask, float2 from, float2 to) {
    float2 way = to - from;
    int steps = int(ceil(length(way)));
    float2 step = way / float(max(steps, 1));
    int2 last = int2(mask.get_width(), mask.get_height()) - 1;
    bool out = false, blocked = false; // out of the area it starts in; then into another
    for (int i = 0; i <= steps; i++) {
        bool opaque = mask.read(uint2(clamp(int2(floor(from + step * float(i))), int2(0), last))).r > 0.5;
        if (!out) out = !opaque;
        else if (opaque) blocked = true;
        else if (blocked) return 0;
    }
    return 1;
}

// A light, added to the maps or taken from them: its color times how much (color.rgb) and how gray (color.a), from its
// middle (effects.xy) out to its radius (effects.z), round or shaped by an image (texture 0, if more.y) turned by an
// angle (more.x); with shadows (effects.w), only where it gets through the mask (texture 1, more.z texels wider each way).
// On an isometric floor (more.w), its maps are the floor as the picture shows it, so its radius is measured across the
// floor, from the picture's way to it: x + y down and y - x up, each half.
ShapedMaps light(Vertex in, texture2d<float> shape, texture2d<float> mask) {
    float2 d = (in.position.xy - in.effects.xy) / in.effects.z, across = d; // across the picture, as normal maps are
    if (in.more.w > 0.5) d = float2(d.y + d.x / 2, d.y - d.x / 2);
    float glow;
    if (in.more.y > 0.5) {
        float c = cos(in.more.x), s = sin(in.more.x);
        constexpr sampler linear(filter::linear, address::clamp_to_zero);
        float4 pixel = shape.sample(linear, float2(d.x * c + d.y * s, d.y * c - d.x * s) * 0.5 + 0.5);
        glow = luma(pixel.rgb) * pixel.a;
    } else {
        glow = saturate(1 - dot(d, d));
        glow *= glow;
    }
    if (glow <= 0) discard_fragment();
    float seen = in.effects.w > 0.5 ? through(mask, in.position.xy + in.more.z, in.effects.xy + in.more.z) : 1;
    float3 light = in.color.rgb * glow;
    // And the way to it, weighted by how much of it gets here, for a scene that shapes its light.
    float weight = max(light.r, max(light.g, light.b)) * seen;
    float2 toward = length(across) > 0.0001 ? -normalize(across) : float2(0);
    return { float4(light * seen, in.color.a * glow), float4(light, 0), float4(toward * weight, weight, 0) };
}

fragment Maps lightFragment(Vertex in [[stage_in]], texture2d<float> shape [[texture(0)]], texture2d<float> mask [[texture(1)]]) {
    ShapedMaps maps = light(in, shape, mask);
    return { maps.shadowed, maps.open };
}

fragment ShapedMaps shapedLightFragment(Vertex in [[stage_in]], texture2d<float> shape [[texture(0)]], texture2d<float> mask [[texture(1)]]) {
    return light(in, shape, mask);
}

// The light capped at daylight (blended with min), so a light no brighter than 1 shows nothing by day: at 1, and under
// clouds (texture 0, how much daylight they leave) the daylight they take more, which lighting takes off again (`lit`),
// so a fire under a cloud is as bright, and the clouds can be read on their own, smooth while the light is sharp.
fragment Maps capFragment(Vertex in [[stage_in]], texture2d<float> clouds [[texture(0)]], constant View &view [[buffer(0)]]) {
    float3 cap = 1 + view.ambient.rgb * (view.clouds > 0.5 ? 1 - clouds.read(uint2(in.position.xy)).r : 0);
    return { float4(cap, 1), float4(cap, 1) };
}

// How much daylight cloud shadows leave at each world pixel, into their map: fBm noise over world pixels, blown color.xy
// pixels by the wind, about color.z pixels big, covering effects.x of the sky and darkening by effects.y, their edges
// soft (effects.z) or dithered.
fragment float4 cloudFragment(Vertex in [[stage_in]], constant View &view [[buffer(0)]]) {
    float2 world = floor(in.position.xy) + view.origin;
    float n = fbm((world - in.color.xy) / in.color.z), edge = mix(1.1, -0.1, in.effects.x); // none at 0, all at 1
    float cloud = in.effects.z > 0.5 ? smoothstep(edge - 0.08, edge + 0.08, n) : step(dither(world), smoothstep(edge - 0.05, edge + 0.05, n));
    return float4(1 - in.effects.y * cloud);
}

// Darker toward the view's corners (multiplied), by up to effects.x, in dithered steps.
fragment Maps vignetteFragment(Vertex in [[stage_in]], constant View &view [[buffer(0)]]) {
    float2 world = floor(in.position.xy) + view.origin;
    float2 d = (world + 0.5 - view.offset - view.canvas / 2) / (view.canvas.y / 2);
    float v = 1 - in.effects.x * smoothstep(0.5, 1.3, length(d * float2(0.7, 1)));
    v = floor(v * 10 + dither(world)) / 10;
    return { float4(v, v, v, 1), float4(v) };
}

// What's opaque, into the mask.
fragment float4 maskFragment(Vertex in [[stage_in]]) { return float4(1); }

// How thick fog is at each world pixel, into its map: fBm noise about color.z pixels big, blown color.xy pixels by the
// wind and churning by effects.y, up to effects.x thick, smoothly (effects.z) or in dithered steps.
fragment float4 fogNoiseFragment(Vertex in [[stage_in]], constant View &view [[buffer(0)]]) {
    float2 world = floor(in.position.xy) + view.origin;
    float thick = smoothstep(0.35, 0.85, fbm((world - in.color.xy) / in.color.z + float2(0, in.effects.y))) * in.effects.x;
    if (in.effects.z < 0.5) thick = floor(thick * 4 + dither(world)) / 4;
    return float4(thick);
}

"""

// The particles' shaders. Each particle is an instance of four `float4`s, as `Screen.lay` writes them: its corner, width
// and height in the pass's pixels; its color; its frame's corners in its texture; and how it's lit (Screen.Lighting).
// It's drawn as a quad of six corners.
let particleShaders = """
struct Particle { float4 place; float4 color; float4 uv; float4 more; };

constant float2 particleCorners[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };

vertex Vertex particleVertex(uint i [[vertex_id]], uint n [[instance_id]], constant Particle *p [[buffer(0)]], constant float2 &size [[buffer(1)]]) {
    Particle q = p[n];
    float2 corner = particleCorners[i];
    float2 xy = (q.place.xy + corner * q.place.zw) / size * 2 - 1;
    Vertex out;
    out.position = float4(xy.x, -xy.y, 0, 1);
    // Turned by quarters, clockwise: the corner shows the frame's corner a quarter back round.
    int quarter = int(q.more.y);
    float2 frame = quarter == 1 ? float2(corner.y, 1 - corner.x) : quarter == 2 ? 1 - corner : quarter == 3 ? float2(1 - corner.y, corner.x) : corner;
    out.uv = mix(q.uv.xy, q.uv.zw, frame);
    out.color = q.color;
    out.effects = float4(0, 1, q.more.x, 0);
    out.more = float4(0);
    out.shade = float3(1);
    out.stand = float4(0);
    return out;
}

// A particle that glows, added to what's under it: unlit, but for rain, which adds the light it catches.
fragment float4 particleGlowFragment(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> shadowed [[texture(1)]],
                                     texture2d<float> open [[texture(2)]], texture2d<float> clouds [[texture(3)]], constant View &view [[buffer(0)]]) {
    constexpr sampler nearest(filter::nearest);
    float4 c = t.sample(nearest, in.uv) * in.color;
    return float4(lit(c.rgb, in.effects.z, float3(1), in.position.xy, view, shadowed, open, clouds) * c.a, c.a);
}

// A particle drawn over what's under it, lit as it says.
fragment float4 particleLitFragment(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> shadowed [[texture(1)]],
                                    texture2d<float> open [[texture(2)]], texture2d<float> clouds [[texture(3)]], constant View &view [[buffer(0)]]) {
    constexpr sampler nearest(filter::nearest);
    float4 c = t.sample(nearest, in.uv) * in.color;
    if (c.a <= 0) discard_fragment();
    return float4(lit(c.rgb, in.effects.z, float3(1), in.position.xy, view, shadowed, open, clouds), c.a);
}

"""

// The bloom's and the bends' shaders.
let glowShaders = """
// Light past daylight, from the open light map (texture 0), times color.r, into the bloom's map.
fragment float4 pastDaylightFragment(Vertex in [[stage_in]], texture2d<float> open [[texture(0)]], constant View &view [[buffer(0)]]) {
    float3 light = at(open, floor(in.position.xy) + view.origin, view).rgb;
    return float4(max(light - 1, float3(0)) * in.color.r, 1);
}

// A Gaussian blur of texture 0 one way, color.xy, about color.z pixels wide: 25 samples, spread over three times that.
fragment float4 blurFragment(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler linear(filter::linear, address::clamp_to_zero);
    float2 size = float2(t.get_width(), t.get_height()), uv = in.position.xy / size;
    float sigma = in.color.z, step = max(sigma * 3 / 12, 1.0);
    float4 sum = float4(0);
    float total = 0;
    for (int i = -12; i <= 12; i++) {
        float x = float(i) * step, w = exp(-x * x / (2 * sigma * sigma));
        sum += t.sample(linear, uv + in.color.xy * x / size) * w;
        total += w;
    }
    return sum / total;
}

// The blurred bloom (texture 0) added over the canvas, times color.
fragment float4 bloomFragment(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    return float4(t.sample(linear, in.uv).rgb * in.color.rgb, 1);
}

// How far a bend moves the picture at each of the game's pixels, into the bends' map, added: color.xy its middle in the
// view, color.z its radius and color.w its strength; effects.x its kind, 0 a ring at effects.y of the radius, 1 haze, 2 a
// swirl; effects.z the time.
fragment float4 bendFragment(Vertex in [[stage_in]]) {
    float2 d = in.position.xy - in.color.xy;
    float r = in.color.z, distance = length(d);
    if (distance >= r) discard_fragment();
    float2 way = distance > 0.001 ? d / distance : float2(0);
    float fall = 1 - distance / r;
    float2 moved;
    if (in.effects.x < 0.5) {
        float x = (distance - in.effects.y * r) / max(r * 0.08, 1.0);
        moved = -way * exp(-x * x) * in.color.w * (1 - in.effects.y) * saturate(fall * 4);
    } else if (in.effects.x < 1.5) {
        float2 p = in.position.xy * 0.3;
        float t = in.effects.z * 4;
        moved = float2(noise(p + float2(0, t)) - 0.5, noise(p + float2(7.3, t)) - 0.5) * 2 * in.color.w * fall;
    } else {
        moved = float2(-way.y, way.x) * in.color.w * fall * fall;
    }
    return float4(moved, 0, 1);
}

// The canvas's copy (texture 0) through the bends' map (texture 6): each pixel from where its bends move it.
fragment float4 throughFragment(Vertex in [[stage_in]], texture2d<float> picture [[texture(0)]], texture2d<float> bends [[texture(6)]],
                                constant View &view [[buffer(0)]]) {
    float2 p = in.position.xy / view.scale;
    float2 moved = bends.read(uint2(clamp(p, float2(0), float2(bends.get_width() - 1, bends.get_height() - 1)))).xy;
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    return picture.sample(nearest, (p + moved) * view.scale / float2(picture.get_width(), picture.get_height()));
}

"""

/// A game's shader file made whole: the engine's header, what its shaders share (`shaderCommon`), then the file with
/// its lines counted from its own first line (`#line`), so errors name it and its lines, then an entry point that calls
/// its function, on one line counted as the file's first.
func shaderSource(_ text: String, name: String, path: String, kind: ShaderKind) -> String {
    let file = "#line 1 \"\(path.replacingOccurrences(of: "\"", with: "\\\""))\"\n"
    let entry = switch kind {
    case .color:
        "fragment float4 spellcrestColor(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> shadowed [[texture(1)]], "
            + "texture2d<float> open [[texture(2)]], texture2d<float> clouds [[texture(3)]], constant View &view [[buffer(0)]], "
            + "constant Values &values [[buffer(1)]]) { "
            + "if (order(in.position.xy / view.scale) >= in.effects.y) discard_fragment(); constexpr sampler nearest(filter::nearest); "
            + "float4 c = t.sample(nearest, in.uv) * in.color; Values v = values; "
            + "float4 s = float4(\(name)(in.uv * float2(t.get_width(), t.get_height()) - in.more.zw, half4(c), v)); "
            + "float3 rgb = mix(s.rgb, float3(1), saturate(in.effects.x)); if (in.effects.w > 0.5) return float4(rgb * s.a, s.a); "
            + "return float4(lit(rgb, in.effects.z, in.shade, in.position.xy, view, shadowed, open, clouds, in.stand), s.a); }"
    case .layer:
        "fragment float4 spellcrestLayer(Vertex in [[stage_in]], texture2d<float> picture [[texture(0)]], constant View &view [[buffer(0)]], "
            + "constant Values &values [[buffer(1)]]) { Values v = values; Layer layer = { picture, view.scale }; "
            + "return float4(\(name)(in.position.xy / view.scale, layer, v)); }"
    }
    return shaderCommon + file + text + "\n" + file + entry + "\n"
}
#endif
