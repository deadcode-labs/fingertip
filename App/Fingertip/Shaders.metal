//
//  Shaders.metal
//  Fingertip
//
//  Humo que se deshilacha desde el borde inferior de la franja indicadora.
//

#include <metal_stdlib>
using namespace metal;

static float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float fbm(float2 p) {
    float sum = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 4; i++) {
        sum += amplitude * valueNoise(p);
        p *= 2.0;
        amplitude *= 0.5;
    }
    return sum;
}

[[ stitchable ]] half4 indicatorSmoke(float2 position, half4 color, float time, float width, float height) {
    float x = position.x / max(width, 1.0);
    float y = position.y / max(height, 1.0); // 0 arriba, 1 abajo (borde de pantalla)

    // Cada columna de x sube a una altura distinta, que varía despacio en el
    // tiempo: así hay zonas que casi no suben y otras que llegan arriba.
    float columnHeight = fbm(float2(x * 2.2, time * 0.12)) * 0.8;
    float plumeTop = 1.0 - columnHeight; // en espacio y: más chico = sube más

    // Turbulencia fina para deshilachar el borde en vez de un corte limpio.
    float2 wispPosition = float2(x * 9.0, y * 5.0 - time * 0.45);
    float wisp = fbm(wispPosition);

    float edge = smoothstep(plumeTop - 0.22, plumeTop + 0.05, y + (wisp - 0.5) * 0.35);
    float smoke = clamp(edge * mix(0.4, 1.0, wisp), 0.0, 1.0);

    half3 base = half3(0.78, 0.82, 0.9); // gris claro, apenas azulado
    half3 rgb = mix(base * 0.5, base, half(smoke));
    half alpha = color.a * half(smoke * 0.55);
    return half4(rgb, alpha);
}
