// Metal 셰이더 소스. Xcode 없이도 빌드되도록 런타임에 컴파일한다.
// 좌표계: 전역 Quartz pt (주 화면 좌상단 원점, y 아래 방향).

let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 screen;    // originX, originY, width, height (pt)
    float4 timeInfo;  // time, scale(px/pt), cornerRadius, poolCapacity
    float4 rain;      // 0, wind(dx/dy), speedMul, lengthMul
    float4 rain2;     // widthMul, opacity, depthStep, depthOfField
    float4 rainColor; // rgb, desktopVisibility
    float4 light;     // dirX, dirY (빛이 오는 방향), specular, rimDark
    float4 water;     // 0, 0, tint, debugShade
    float4 counts;    // edgeCount, edgeLength, screenIndex, cornerExponent
};

// ---------- 유틸 ----------

inline uint pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
inline float rnd(uint v) { return float(pcg(v)) * (1.0 / 4294967296.0); }

inline float hash11(float p) { p = fract(p * 0.1031); p *= p + 33.33; p *= p + p; return fract(p); }
inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
inline float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}
inline float vnoise1(float x) {
    float i = floor(x), f = fract(x);
    float u = f * f * (3.0 - 2.0 * f);
    return mix(hash11(i), hash11(i + 1.0), u);
}
inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash12(i), b = hash12(i + float2(1, 0)), c = hash12(i + float2(0, 1)), d = hash12(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

inline float4 toClip(float2 g, constant Uniforms& u) {
    float2 l = (g - u.screen.xy) / u.screen.zw;
    return float4(l.x * 2.0 - 1.0, 1.0 - l.y * 2.0, 0.0, 1.0);
}
inline float2 worldOf(float4 pos, constant Uniforms& u) { return pos.xy / u.timeInfo.y + u.screen.xy; }

/// 해당 픽셀을 덮고 있는 가장 앞 창의 순위. r = 전역 순위, g = 이 모니터 안에서의 순위 (0 = 맨 앞, 255 = 바탕화면)
inline float2 maskRanks(texture2d<float> mask, float4 pos) {
    uint2 c = min(uint2(pos.xy), uint2(mask.get_width() - 1, mask.get_height() - 1));
    return mask.read(c).rg * 255.0;
}
inline float maskRank(texture2d<float> mask, float4 pos) { return maskRanks(mask, pos).x; }
inline float2 quadCorner(uint vid) { return float2(float(vid & 1u), float(vid >> 1u)); }

// 순위 + 소속 모니터 인코딩 (rank + 256 * screen)
inline float decodeScreen(float enc) { return floor(enc / 256.0 + 0.001); }
inline float decodeRank(float enc) { return enc - decodeScreen(enc) * 256.0; }
/// 이 모니터 소속이고, 앞 창에 가려지지 않았는지
inline bool visibleFor(float enc, float4 pos, texture2d<float> mask, constant Uniforms& u) {
    if (abs(decodeScreen(enc) - u.counts.z) > 0.5) return false;
    return maskRank(mask, pos) >= decodeRank(enc) - 0.5;
}

/// macOS 창 모서리(연속 곡률)를 초타원으로 근사한 거리. d: 점 − 모서리 중심, E: 곡선 길이, n: 지수(2 = 원)
inline float cornerDist(float2 d, float E, float n, thread float2& nrm) {
    float2 a = max(abs(d) / E, float2(1e-4));
    float2 an = pow(a, float2(n));
    float sum = an.x + an.y;
    float L = pow(sum, 1.0 / n);
    float2 grad = pow(a, float2(n - 1.0)) * pow(sum, 1.0 / n - 1.0);
    float gl = max(length(grad), 1e-3);
    float2 sg = float2(d.x < 0.0 ? -1.0 : 1.0, d.y < 0.0 ? -1.0 : 1.0);
    nrm = normalize(grad * sg);
    return (L - 1.0) * E / gl;
}
inline float cornerExtent(constant Uniforms& u) { return u.timeInfo.z * (1.0 + (u.counts.w - 2.0) / 6.0); }

// ---------- 물 셰이딩 ----------

/// 화면 왼쪽 위(빛 방향) 바깥에 있는 광원. 가까운 곳은 밝고 멀어질수록(오른쪽 아래로) 어두워진다.
inline float2 lightAt(float2 g, constant Uniforms& u, thread float& falloff) {
    float2 c = u.screen.xy + u.screen.zw * 0.5;
    float diag = length(u.screen.zw);
    float2 P = c + normalize(u.light.xy) * diag * 0.9;
    float2 d = P - g;
    float dist = length(d);
    float k = dist / (0.7 * diag);
    falloff = 1.3 / (1.0 + k * k);
    return d / max(dist, 1e-3);
}

/// 물방울(창 전면 물방울, 낙수, 튀김)용 셰이딩. 공 모양이라 평행광 하나로 충분하다.
/// rimStart·rimMul: 가장자리 어둠이 시작되는 기울기와 세기 (물방울은 기본값, 수막 앞선은 윤곽 근처에만 얇게)
float4 shadeDrop(float2 n2, float thick, float cover, float4 pos, constant Uniforms& u,
                 float rimStart = 0.06, float rimMul = 1.0) {
    float l2 = dot(n2, n2);
    if (l2 > 0.97) n2 *= rsqrt(l2) * 0.985;
    float3 n = float3(n2, sqrt(max(1.0 - dot(n2, n2), 0.0)));
    float3 L = normalize(float3(u.light.x, u.light.y, 0.9));
    float3 H = normalize(L + float3(0, 0, 1));
    float ndh = saturate(dot(n, H));
    float spec = (pow(ndh, 140.0) * 1.7 + pow(ndh, 20.0) * 0.10) * u.light.z;
    float edge = 1.0 - n.z;
    float rim = smoothstep(rimStart, max(0.8, rimStart + 0.12), edge) * u.light.w * rimMul;
    float2 nd = n2 * rsqrt(max(dot(n2, n2), 1e-6));
    float2 ld = normalize(u.light.xy);
    // 빛 반대편 안쪽으로 모이는 코스틱
    float caus = saturate(dot(nd, -ld)) * smoothstep(0.02, 0.3, edge) * (1.0 - smoothstep(0.4, 0.85, edge))
               * 0.45 * u.light.z;
    float body = u.water.z * (0.35 + 0.65 * saturate(thick));
    float lit = spec + caus;
    float a = saturate(rim * 0.6 + body + lit) * cover;
    float3 col = (lit + body * float3(0.72, 0.8, 0.88)) * cover;
    return float4(min(col, float3(a)), a);
}

/// shadeDrop과 같은 빛에서 하이라이트 주변이 얼마나 빛을 받는지 (지수가 낮을수록 넓게)
inline float specGlow(float2 n2, constant Uniforms& u, float expo) {
    float l2 = dot(n2, n2);
    if (l2 > 0.97) n2 *= rsqrt(l2) * 0.985;
    float3 n = float3(n2, sqrt(max(1.0 - dot(n2, n2), 0.0)));
    float3 H = normalize(normalize(float3(u.light.x, u.light.y, 0.9)) + float3(0, 0, 1));
    return pow(saturate(dot(n, H)), expo);
}

/// 프리멀티플라이드 색 col 아래에 색 막을 깐다
inline float4 underTint(float4 col, float3 tint, float alpha) {
    return col + (1.0 - col.a) * float4(tint * alpha, alpha);
}

/// shadeDrop 하이라이트 옆에 평행하게 붙는 어두운 선 (0..1). 밝은 배경에서 흰 하이라이트가 묻히지 않게 쓴다.
/// 빛 방향을 살짝 비튼 "복사본 하이라이트"에서 원래 하이라이트를 뺀 것이라, 하이라이트와 같은 굵기로 매끈하게 따라붙는다.
inline float highlightShadow(float2 n2, constant Uniforms& u) {
    float l2 = dot(n2, n2);
    if (l2 > 0.97) n2 *= rsqrt(l2) * 0.985;
    float3 n = float3(n2, sqrt(max(1.0 - dot(n2, n2), 0.0)));
    float3 H = normalize(normalize(float3(u.light.x, u.light.y, 0.9)) + float3(0, 0, 1));
    float2 ld = normalize(u.light.xy);
    float3 Hs = normalize(H - float3(ld * 0.09, 0.0));
    // 하이라이트보다 날카로운 지수로 계산해서, 하이라이트가 넓게 맺히는 완만한 곳에서도 선이 번지지 않게
    float s = pow(saturate(dot(n, H)), 260.0);
    float ss = pow(saturate(dot(n, Hs)), 260.0);
    return saturate(ss - s);
}

/// 띠·막대 모양 물(윗변, 옆 물줄기, 쏟아지는 물줄기, 수막)용 셰이딩.
/// n2: 화면 평면 법선 (길이 < 1, y 아래)
/// axis: 물이 휘는 방향. 한 방향으로만 휘므로 하이라이트도 그 축에 투영한 빛으로 계산해야 선으로 맺힌다.
/// featurePx: 물의 픽셀 폭. 얇을수록 하이라이트를 부드럽게 해서 픽셀 단위 깜빡임을 막는다.
/// lineDark: 하이라이트 옆 그늘진 쪽에 생기는 어두운 선의 세기. 밝은 배경에서도 물로 보이게 한다.
float4 shadeWater(float2 n2, float2 axis, float thick, float cover, float featurePx, float lineDark, float4 pos,
                  constant Uniforms& u) {
    float aa = smoothstep(2.0, 9.0, featurePx);
    n2 *= mix(0.45, 1.0, aa);
    float l2 = dot(n2, n2);
    if (l2 > 0.97) n2 *= rsqrt(l2) * 0.985;
    float3 n = float3(n2, sqrt(max(1.0 - dot(n2, n2), 0.0)));
    float fall;
    float2 ld = lightAt(worldOf(pos, u), u, fall);
    float3 L = normalize(float3(ld, 0.75));
    float3 H = normalize(L + float3(0, 0, 1));
    float axisAtt = 1.0;
    if (dot(axis, axis) > 0.25) {
        H = normalize(float3(dot(H.xy, axis) * axis, H.z));
        axisAtt = mix(0.55, 1.0, abs(dot(ld, axis)));
    }
    float ndh = saturate(dot(n, H));
    float expo = mix(20.0, 80.0, aa);
    float spec = (pow(ndh, expo) * 0.6 + pow(ndh, 6.0) * 0.04) * u.light.z * axisAtt * fall;
    float edge = 1.0 - n.z;
    float facing = dot(n2, ld);
    float fd = (facing + 0.4) / 0.13;
    float dark = (smoothstep(0.35, 0.95, edge) * 0.35 + exp(-fd * fd) * lineDark) * u.light.w;
    float2 nd = n2 * rsqrt(max(dot(n2, n2), 1e-6));
    float caus = saturate(dot(nd, -ld)) * smoothstep(0.02, 0.3, edge) * (1.0 - smoothstep(0.4, 0.85, edge))
               * 0.3 * u.light.z * fall;

    float body = u.water.z * (0.35 + 0.65 * saturate(thick));
    float lit = spec + caus;
    float a = saturate(body + dark * 0.7 + lit) * cover;
    float3 col = (lit + body * float3(0.72, 0.8, 0.88)) * cover;
    return float4(min(col, float3(a)), a);
}

/// 프리멀티플라이드 색 col 아래에 어두운 선을 깐다 (흰 하이라이트 밑의 어두운 선)
inline float4 underDark(float4 col, float dk) {
    return col + (1.0 - col.a) * float4(0.06, 0.07, 0.09, 1.0) * dk;
}

// ---------- 가려짐 마스크 ----------

struct MaskOut {
    float4 pos [[position]];
    float2 local;
    float2 halfSize [[flat]];
    float2 value [[flat]];
};

vertex MaskOut maskVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          constant Uniforms& u [[buffer(0)]], const device float4* rects [[buffer(1)]]) {
    float4 r = rects[iid * 2];
    float2 ranks = rects[iid * 2 + 1].xy;
    float2 c = quadCorner(vid);
    MaskOut o;
    o.pos = toClip(r.xy + c * r.zw, u);
    o.local = (c - 0.5) * r.zw;
    o.halfSize = r.zw * 0.5;
    o.value = min(ranks, float2(254.0)) / 255.0;
    return o;
}

fragment float2 maskFragment(MaskOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float E = min(cornerExtent(u), min(in.halfSize.x, in.halfSize.y));
    float2 q = abs(in.local) - (in.halfSize - E);
    if (q.x > 0.0 && q.y > 0.0) {
        float2 nn;
        if (cornerDist(q, E, u.counts.w, nn) > 0.0) discard_fragment();
    }
    return in.value;
}

// ---------- 빗줄기 (상태 없음: 인스턴스 번호와 시간만으로 계산) ----------

struct RainOut {
    float4 pos [[position]];
    float2 uv;
    float depth [[flat]];
    float alpha [[flat]];
    float side [[flat]];
};

vertex RainOut rainVertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms& u [[buffer(0)]]) {
    float W = u.screen.z, H = u.screen.w;
    float t = u.timeInfo.x;
    float d = rnd(iid * 7u + 1u);            // 0 가까움 .. 1 멀리
    float near = 1.0 - d;
    float persp = mix(0.45, 1.7, near * near);
    float speed = 1300.0 * persp * u.rain.z * (0.85 + 0.3 * rnd(iid * 7u + 2u));
    float len = max(5.0, speed * 0.028 * u.rain.w);
    float wind = u.rain.y;
    float span = H + len + 80.0;
    float ph = t * speed / span + rnd(iid * 7u + 3u);
    float cyc = floor(ph);
    float f = ph - cyc;
    uint cs = pcg(iid * 7u + 4u + uint(int(cyc)) * 2654435761u);
    float extraL = max(0.0, wind) * H, extraR = max(0.0, -wind) * H;
    float x0 = -extraL - 20.0 + rnd(cs) * (W + extraL + extraR + 40.0);
    float yHead = -20.0 + f * span;
    float xHead = x0 + wind * yHead;
    float2 dir = normalize(float2(wind, 1.0));
    float2 perp = float2(-dir.y, dir.x);
    float blur = u.rain2.w * near * near;
    float width = (0.7 + 0.9 * near + 2.4 * blur) * u.rain2.x;
    float px = 1.0 / u.timeInfo.y;
    float hw = width * 0.5 + px;
    float2 c = quadCorner(vid);
    float2 local = float2(xHead, yHead) - dir * len * (1.0 - c.y) + perp * hw * (c.x * 2.0 - 1.0);

    RainOut o;
    o.pos = toClip(local + u.screen.xy, u);
    o.uv = float2(c.y, (c.x * 2.0 - 1.0) * hw / (width * 0.5));
    o.depth = d;
    o.alpha = u.rain2.y * mix(0.35, 1.0, near) / (1.0 + 2.0 * blur) * (0.6 + 0.4 * rnd(cs + 11u));
    o.side = dot(perp, u.light.xy) >= 0.0 ? 1.0 : -1.0;
    return o;
}

fragment float4 rainFragment(RainOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                             texture2d<float> mask [[texture(0)]]) {
    float2 ranks = maskRanks(mask, in.pos);
    float rank = ranks.y;                    // 이 모니터 안에서의 순위
    if (rank < 0.5) discard_fragment();      // 각 모니터의 맨 위 창에는 비가 보이지 않음
    bool desktop = ranks.x > 254.5;
    float w = desktop ? 1.0 : saturate(rank * u.rain2.z);
    float vis = smoothstep(in.depth - 0.05, in.depth + 0.05, w);
    if (desktop) vis *= u.rainColor.w;
    if (vis < 0.002) discard_fragment();
    float s = in.uv.y;
    float core = exp(-s * s * 2.5);
    float hs = s - in.side * 0.45;
    float hl = exp(-hs * hs * 6.0);
    float along = smoothstep(0.0, 0.45, in.uv.x) * smoothstep(1.0, 0.86, in.uv.x);
    float a = (core * 0.45 + hl * 0.55) * along * in.alpha * vis;
    float3 col = u.rainColor.rgb * (0.8 + 0.5 * hl);
    return float4(min(col * a, float3(a)), a);
}

// ---------- 창 윗변에 고인 물 + 위쪽 둥근 모서리 ----------
// 고인 물과 옆면 물줄기는 둘 다 "창 외곽선(둥근 사각형)으로부터 바깥쪽 거리"로 그린다.
// 모서리 호의 끝(옆면 시작점)에서 두께가 물줄기 폭과 같아지므로 두 셰이더가 이음매 없이 만난다.

struct PoolOut {
    float4 pos [[position]];
    uint idx [[flat]];
};

vertex PoolOut poolVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          constant Uniforms& u [[buffer(0)]], const device float4* pools [[buffer(1)]]) {
    float4 a = pools[iid * 4], b = pools[iid * 4 + 1], c3 = pools[iid * 4 + 2];
    float R = c3.z;
    float maxT = c3.w * max(b.w, 1.0) + 4.0;
    float2 c = quadCorner(vid);
    float x = mix(a.x - maxT - 2.0, a.x + a.z + maxT + 2.0, c.x);
    float y = mix(a.y - maxT - 2.0, a.y + max(R, maxT) + 1.0, c.y);
    PoolOut o;
    o.pos = toClip(float2(x, y), u);
    o.idx = iid;
    return o;
}

inline float catmull(float p0, float p1, float p2, float p3, float t) {
    float t2 = t * t, t3 = t2 * t;
    return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3);
}
inline float catmullD(float p0, float p1, float p2, float p3, float t) {
    return 0.5 * ((-p0 + p2) + 2.0 * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t + 3.0 * (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t * t);
}

/// 높이장을 부드럽게 샘플링: 높이와 기울기(dh/dx)
inline float2 sampleHeights(const device float* heights, int off, int n, float dx, float x) {
    float ft = x / dx - 0.5;
    float fl = floor(ft);
    int i0 = clamp(int(fl), 0, n - 1);
    int i1 = min(i0 + 1, n - 1);
    int im = max(i0 - 1, 0), ip = min(i1 + 1, n - 1);
    float fr = saturate(ft - fl);
    float p0 = heights[off + im], p1 = heights[off + i0], p2 = heights[off + i1], p3 = heights[off + ip];
    return float2(max(catmull(p0, p1, p2, p3, fr), 0.0), catmullD(p0, p1, p2, p3, fr) / dx);
}

fragment float4 poolFragment(PoolOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                             const device float4* pools [[buffer(1)]], const device float* heights [[buffer(2)]],
                             texture2d<float> mask [[texture(0)]]) {
    float4 a = pools[in.idx * 4], b = pools[in.idx * 4 + 1], c3 = pools[in.idx * 4 + 2], c4 = pools[in.idx * 4 + 3];
    if (!visibleFor(a.w, in.pos, mask, u)) discard_fragment();
    float2 g = worldOf(in.pos, u);
    float width = a.z;
    float time = u.timeInfo.x;
    int n = int(b.y), off = int(b.x);
    float dx = b.z;
    float px = 1.0 / u.timeInfo.y;
    float cap = max(u.timeInfo.w, 1.0);

    float R = c3.z;
    float2 lp = g - a.xy;                 // 창 좌상단 기준
    float dist;                           // 외곽선에서 바깥으로의 거리
    float2 nO;                            // 바깥 방향 법선
    float xs;                             // 높이장을 읽을 x
    float theta = 0.0;                    // 0 = 윗변, 1 = 옆면이 시작되는 곳 (모서리 호의 진행률)
    float join = 0.0;                     // 이 모서리로 이어지는 물줄기 폭
    float reach = 0.0;                    // 물줄기 머리가 이 모서리 곡선을 돈 정도 (0..1, 다 돌면 1.2)
    if (lp.x < R || lp.x > width - R) {
        bool left = lp.x < R;
        float2 C = float2(left ? R : width - R, R);
        float2 d = lp - C;
        if (d.y > 0.0) discard_fragment();                  // 옆면 영역은 물줄기 셰이더 담당
        dist = cornerDist(d, R, u.counts.w, nO);
        theta = saturate(atan2(abs(nO.x), -nO.y) / 1.5707963);
        xs = lp.x - nO.x * dist;
        join = left ? c3.x : c3.y;
        reach = left ? c4.x : c4.y;
    } else {
        if (lp.x < 0.0 || lp.x > width) discard_fragment();   // 모서리 반경이 0일 때
        nO = float2(0.0, -1.0);
        dist = -lp.y;
        xs = lp.x;
    }
    if (dist < -px) discard_fragment();

    float2 hs = sampleHeights(heights, off, n, dx, clamp(xs, 0.0, width));
    // 물결은 과장해서 보여준다: 주변 평균에서 벗어난 만큼을 키운다 (물리는 그대로 두고 그리기만)
    float hAvg = (sampleHeights(heights, off, n, dx, clamp(xs - 18.0, 0.0, width)).x
                + sampleHeights(heights, off, n, dx, clamp(xs + 18.0, 0.0, width)).x + hs.x) / 3.0;
    float dev = clamp(hs.x - hAvg, -1.2, 1.2);        // 출렁여 쌓인 큰 물더미는 과장하지 않는다
    hs = float2(max(hs.x + dev * 0.5, 0.0), hs.y * mix(1.5, 1.0, saturate(abs(hs.x - hAvg) / 3.0)));
    float h = hs.x;
    // 모서리: 물줄기가 있으면 그 폭으로 자연스럽게 좁아지고, 없으면 둥글게 끝난다 (join은 서서히 변함)
    float tt = smoothstep(0.0, 1.0, theta);
    // 호 끝(θ=1)에서 두께가 정확히 join(= 물줄기 폭 × 이음 계수)이 되어 물줄기 셰이더와 맞물린다
    float jf = saturate(join * 4.0);
    // 물줄기 폭으로 굵히는 건 물줄기 머리가 곡선을 돈 데까지만 (앞쪽은 부드럽게). 물이 모서리를 따라 흘러 내려가 보이게
    jf *= 1.0 - smoothstep(reach - 0.15, reach, theta);
    float t = mix(h * (1.0 - smoothstep(0.3, 1.0, theta)), mix(h, join, tt), jf);   // θ=0에서 윗변 높이, θ=1에서 물줄기 폭
    if (t < 0.18) discard_fragment();

    float cover = (1.0 - smoothstep(t - px * 0.6, t + px * 0.6, dist)) * smoothstep(-px, 0.0, dist);
    if (cover <= 0.001) discard_fragment();
    float v = saturate(dist / t);
    // 윗변은 평평한 물 표면: 휘어 보이는 부력 없이, 출렁임 기울기와 잔잔한 일렁임만 빛을 움직인다.
    // 옆면 물줄기로 이어지는 모서리에서만 원통형 단면으로 바뀐다.
    // 맨 위 1pt 남짓만 살짝 휘어 수면 반사선을 만든다 (전체가 부푼 느낌은 없게)
    // 수면 반사선은 물결과 잔잔한 일렁임에 따라 세기가 달라진다 (일직선으로 보이지 않게)
    float glintVar = 0.55 + 0.9 * vnoise(float2(xs * 0.035 - time * 0.4, time * 0.25)) + clamp(-hs.y * 3.0, -0.4, 0.4);
    // 윗변 표면은 평평하게 두고(부푼 느낌 없음), 수면 선은 아래에서 명시적으로 그린다.
    // 옆면 물줄기 쪽으로 갈수록 반원통 단면(창 쪽 −, 바깥쪽 +)으로 바뀐다. 물줄기 셰이더와 같은 단면
    float prof = mix(-0.4, 0.9, v) * tt * jf;
    float2 tangent = float2(-nO.y, nO.x);
    float shimmer = (vnoise(float2(xs * 0.05 - time * 0.6, time * 0.7)) - 0.5) * 0.4;
    float ripple = (-hs.y * 1.8 + shimmer) * (1.0 - tt) * mix(0.45, 1.0, v);
    float2 n2 = nO * prof + tangent * clamp(ripple, -0.75, 0.75);
    float4 col = shadeWater(n2, nO, t / cap, cover, t * u.timeInfo.y, 0.3, in.pos, u);
    // 수면 선 (밝은 배경에서도 물처럼 보이게): 수면 바로 안쪽에 연한 어두운 선, 그 아래 밝은 반사선
    float topMask = (1.0 - tt) * saturate((t - 1.0) / 1.2);
    float lw = max(0.5, 0.9 * px);
    float dLine = exp(-pow((dist - (t - 0.6)) / lw, 2.0)) * topMask;
    float fall;
    lightAt(g, u, fall);
    float bLine = exp(-pow((dist - (t - 1.9)) / (lw * 1.2), 2.0)) * topMask
                * clamp(glintVar, 0.15, 1.4) * fall * 0.45 * u.light.z;
    col = underDark(col, dLine * cover * (0.12 + 0.25 * u.light.w));
    float bright = min(bLine * cover, 0.9);
    col = float4(bright) + col * (1.0 - bright);
    return col * smoothstep(0.18, 0.8, t);
}

// ---------- 창 옆면을 타고 흐르는 물줄기 ----------
// 경로: 옆면 직선 → 아래 모서리 곡선을 65°까지 돌며 가늘어짐 → 거기서 방울이 떨어진다.
// r0 = (옆면 x, 윗변 y, 밑변 y, side), r1 = (머리 y, 꼬리 y, 폭, 순위), r2 = (seed, 유량, 모서리 길이 E, 0), r3 = (이음 계수)

struct RivOut {
    float4 pos [[position]];
    uint idx [[flat]];
};

vertex RivOut rivuletVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            constant Uniforms& u [[buffer(0)]], const device float4* rivs [[buffer(1)]]) {
    float4 r0 = rivs[iid * 4], r1 = rivs[iid * 4 + 1], r2 = rivs[iid * 4 + 2];
    float E = r2.z, side = r0.w;
    float m = r1.z * 2.6 + 3.0;
    bool reached = r1.x >= r0.z - E - 0.5;
    float inward = E + m;
    float xa = side < 0.0 ? r0.x - m : r0.x - inward;
    float xb = side < 0.0 ? r0.x + inward : r0.x + m;
    float2 c = quadCorner(vid);
    float yEnd = reached ? r0.z + m : r1.x + m;
    RivOut o;
    o.pos = toClip(float2(mix(xa, xb, c.x), mix(max(r1.y, r0.y + E) - 1.0, yEnd, c.y)), u);
    o.idx = iid;
    return o;
}

fragment float4 rivuletFragment(RivOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                const device float4* rivs [[buffer(1)]],
                                texture2d<float> mask [[texture(0)]]) {
    float4 r0 = rivs[in.idx * 4], r1 = rivs[in.idx * 4 + 1], r2 = rivs[in.idx * 4 + 2], r3 = rivs[in.idx * 4 + 3];
    if (!visibleFor(r1.w, in.pos, mask, u)) discard_fragment();
    float connect = r3.x;
    float2 g = worldOf(in.pos, u);
    float edgeX = r0.x, top = r0.y, bottom = r0.z, side = r0.w;
    float tail = r1.y, w = r1.z;
    float seed = r2.x, E = r2.z;
    float start = top + E;                   // 옆면 직선 시작 (위쪽 모서리는 고인 물 셰이더 담당)
    float sideEnd = bottom - E;              // 옆면 직선 끝
    float head = clamp(r1.x, start, sideEnd);
    bool reached = r1.x >= sideEnd - 0.5;
    if (g.y < start) discard_fragment();
    float px = 1.0 / u.timeInfo.y;
    float t = u.timeInfo.x;

    // 폭: 은은하고 빠른 굵기 변화 (위상 속도는 고정값: 시간 × 변하는 값은 지직거림의 원인)
    float y = min(g.y, head);
    float ease = smoothstep(start, start + 40.0, y);          // 모서리 이음부에서는 폭·굽이 고정
    float easeEnd = 1.0 - smoothstep(sideEnd - 30.0, sideEnd, y);
    float wobble = (vnoise1(y * 0.03 + seed) - 0.5) * 0.2 + (vnoise1((y - t * 160.0) * 0.03 + seed * 3.1) - 0.5) * 0.25;
    float wl = w * max(0.7, 1.0 + wobble * ease);
    wl *= mix(connect, 1.0, ease);                            // 위쪽 모서리와 같은 폭에서 출발
    wl *= smoothstep(tail, tail + 14.0, g.y);                 // 꼬리: 흐름이 멈추면 위에서부터 빠짐
    // 뱀처럼 불규칙하게 굽이치는 흐름: 굽이 모양이 아래로 흘러가면서(첫 좌표) 동시에 제자리에서도 꿈틀거린다(둘째 좌표).
    // 창 안쪽을 살짝 침범하기도 한다
    float meander = ((vnoise(float2(y * 0.035 - t * 3.2, t * 1.5 + seed)) - 0.5) * 2.0
                   + (vnoise(float2(y * 0.09 - t * 6.0, t * 2.9 + seed * 2.3)) - 0.5) * 0.8) * min(2.6, w * 0.7) * ease * easeEnd;
    if (wl < 0.05) discard_fragment();
    float minW = 1.6 * px;                                    // 픽셀보다 가늘면 깜빡이므로 최소 굵기 유지, 대신 투명하게
    float thinFade = saturate(wl / minW);
    wl = max(wl, minW);

    // 외곽선까지의 거리와 바깥 법선
    float dist;
    float2 nO;
    float capCover = 1.0;
    float along = 0.0;
    if (g.y <= sideEnd || !reached) {
        nO = float2(side, 0.0);
        // 굽이: 안쪽으로는 파고들 수 있지만, 바깥으로 굽을 때는 창에 붙은 쪽은 그대로 두고 바깥쪽만 불룩해진다
        // (물줄기가 창에서 떨어져 보이지 않게)
        float inner = min(meander, 0.0);
        dist = (g.x - edgeX) * side - inner;
        wl = meander + wl - inner;
        if (!reached && g.y > head) {
            // 아직 내려가는 중인 머리: 둥근 방울
            float hr = wl * 0.8;
            along = (g.y - head) / hr;
            float across = (dist - wl * 0.5) / (wl * 0.5);
            capCover = 1.0 - smoothstep(1.0 - px / hr, 1.0 + px / hr, sqrt(along * along + across * across));
            dist = clamp(dist, 0.0, wl);
        }
    } else {
        // 아래 모서리 곡선을 따라 돌며 점점 가늘어지다가 kDripAngle에서 끝난다 (거기 방울이 맺혀 떨어진다)
        float2 C = float2(edgeX - side * E, sideEnd);
        float2 dc = g - C;
        if (dc.x * side < -0.5) discard_fragment();           // 곡선 구간을 지나 밑변 쪽은 그리지 않음
        dist = cornerDist(dc, E, u.counts.w, nO);
        float2 aa = max(abs(dc) / E, float2(1e-4));
        float nh = u.counts.w * 0.5;
        float ang = atan2(pow(aa.y, nh), pow(aa.x, nh));      // 초타원 매개변수 각도 (옆면 0 → 밑변 π/2)
        const float kDripAngle = 65.0 * 3.14159265 / 180.0;
        float prog = ang / kDripAngle;
        wl *= mix(1.0, 0.5, saturate(prog));
        capCover = 1.0 - smoothstep(0.93, 1.02, prog);
        // 머리가 곡선을 따라 내려오는 중이면 거기까지만 (다 오면 머리 진행이 1.25라 위 끝부분 모양 그대로)
        float headProg = (r1.x - sideEnd) / (E * kDripAngle);
        capCover *= 1.0 - smoothstep(headProg - 0.2, headProg, prog);
    }
    float cover = (1.0 - smoothstep(wl - px * 0.6, wl + px * 0.6, dist)) * smoothstep(-px, 0.0, dist) * capCover * thinFade;
    if (cover <= 0.001) discard_fragment();
    float v = saturate(dist / wl);
    // 흐름을 따라 내려가는 반짝임 (시간 주파수를 초당 2~3회 이하로 유지해야 깜빡임처럼 보이지 않는다)
    // 모서리 이음부에서는 0이라 고인 물과 음영이 일치
    float glint = (vnoise1((y - t * 110.0) * 0.022 + seed) - 0.5) * 0.9 * ease;
    float2 tangent = float2(-nO.y, nO.x);
    // 단면: 유리에 젖어 붙은 창 쪽은 완만(−0.4), 바깥 자유 표면 쪽은 가파름(+0.9)
    float2 n2 = nO * mix(-0.4, 0.9, v) + tangent * (glint + clamp(along, 0.0, 1.0) * 0.6) * side;
    return shadeWater(n2, nO, saturate(w / 5.0), cover, wl * u.timeInfo.y, 0.3, in.pos, u);
}

// ---------- 물방울 (낙수, 유리 위 물방울, 튀는 물) ----------

struct DropOut {
    float4 pos [[position]];
    float2 local;
    float r [[flat]];
    float stretch [[flat]];
    float2 dir [[flat]];
    float rank [[flat]];
    float alpha [[flat]];
    float light [[flat]];     // 1 = 튀김: 연하게 그림
};

inline DropOut makeDrop(uint vid, float2 center, float r, float2 dir, float stretch, float rank, float alpha,
                        constant Uniforms& u) {
    float px = 1.5 / u.timeInfo.y;
    float2 perp = float2(-dir.y, dir.x);
    float2 c = quadCorner(vid);
    float across = mix(-r - px, r + px, c.x);
    float along = mix(-r * stretch - px, r + px, c.y);
    DropOut o;
    o.pos = toClip(center + perp * across + dir * along, u);
    o.local = float2(across, along);
    o.r = r; o.stretch = stretch; o.dir = dir; o.rank = rank; o.alpha = abs(alpha);
    o.light = alpha < 0.0 ? 1.0 : 0.0;
    return o;
}

vertex DropOut dropVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          constant Uniforms& u [[buffer(0)]], const device float4* drops [[buffer(1)]]) {
    float4 a = drops[iid * 2], b = drops[iid * 2 + 1];
    return makeDrop(vid, a.xy, a.z, b.xy, b.z, b.w, a.w, u);
}

/// 빗방울이 창 윗변과 화면 바닥에 부딪혀 튀는 물. 역시 상태 없이 GPU에서 계산.
vertex DropOut splashVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            constant Uniforms& u [[buffer(0)]], const device float4* edges [[buffer(1)]]) {
    uint k = iid / 5u, j = iid % 5u;
    float period = 0.55, life = 0.36;
    float ph = u.timeInfo.x / period + rnd(k * 13u + 1u);
    float cyc = floor(ph);
    float tau = (ph - cyc) * period;
    uint seed = pcg(k * 13u + 7u + uint(int(cyc)) * 2246822519u);
    int ne = int(u.counts.x);
    float s = rnd(seed) * u.counts.y;
    int e = 0;
    for (int i = 1; i < ne; i++) { if (edges[i * 2 + 1].x <= s) e = i; }
    float4 ed = edges[e * 2];
    float4 em = edges[e * 2 + 1];
    float x = ed.x + (s - em.x) / max(em.y, 0.01);
    float ang = (rnd(seed + j * 7919u) - 0.5) * 2.4;
    float sp = mix(60.0, 180.0, rnd(seed + j * 104729u)) * (j == 0u ? 0.5 : 1.0);
    float2 v0 = float2(sin(ang), -cos(ang)) * sp + float2(u.rain.y * 60.0, 0.0);
    float2 p = float2(x, ed.z) + v0 * tau + float2(0.0, 800.0 * tau * tau);
    float2 v = v0 + float2(0.0, 1600.0 * tau);
    float spd = length(v);
    float r = mix(0.8, 1.8, rnd(seed + j * 31337u));
    // 약 65%는 꼭대기를 지나 떨어지기 시작하면 곧 사라진다 (떨어지는 방울이 너무 많아 보이지 않게)
    float apex = max(-v0.y, 0.0) / 1600.0;
    float myLife = rnd(seed + j * 7717u) < 0.65 ? min(life, apex + mix(0.03, 0.08, rnd(seed + j * 5153u))) : life;
    float alive = tau < myLife ? 1.0 - tau / myLife : 0.0;
    DropOut o = makeDrop(vid, p, r, v / max(spd, 1.0), 1.0 + min(2.0, spd * 0.004), ed.w, -alive, u);
    if (alive <= 0.0) o.pos = float4(0.0);
    return o;
}

fragment float4 dropFragment(DropOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                             texture2d<float> mask [[texture(0)]]) {
    if (!visibleFor(in.rank, in.pos, mask, u)) discard_fragment();
    float r = in.r;
    float2 l = in.local;
    float qy = l.y > 0.0 ? l.y / r : l.y / (r * in.stretch);
    float qx = l.x / r;
    if (l.y < 0.0) qx /= mix(1.0, 0.6, saturate(-qy));   // 꼬리 쪽은 가늘게 (눈물방울 모양)
    float d = length(float2(qx, qy));
    float aa = (1.0 / u.timeInfo.y) / r;
    float cover = (1.0 - smoothstep(1.0 - aa, 1.0 + aa, d)) * in.alpha;
    if (cover <= 0.001) discard_fragment();
    float2 nl = float2(qx, qy) * (d > 0.985 ? 0.985 / d : 1.0);
    float2 perp = float2(-in.dir.y, in.dir.x);
    float2 n2 = perp * nl.x + in.dir * nl.y;
    // 튀김은 테두리가 진해 보이지 않게 연하게
    if (in.light > 0.5) { n2 *= 0.8; cover *= 0.85; }
    return shadeDrop(n2, saturate(r / 4.0), cover, in.pos, u);
}

// ---------- 창이 닫힐 때 화면을 타고 흘러내리는 수막 ----------

struct CurtainOut {
    float4 pos [[position]];
    uint idx [[flat]];
};

vertex CurtainOut curtainVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                constant Uniforms& u [[buffer(0)]], const device float4* cs [[buffer(1)]]) {
    float4 c0 = cs[iid * 3], c1 = cs[iid * 3 + 1], c2 = cs[iid * 3 + 2];
    float2 c = quadCorner(vid);
    // 아래쪽은 화면 바닥까지가 아니라 지금 앞선이 닿을 수 있는 곳까지만 (그 아래는 물이 없는데 픽셀마다 계산하던 곳).
    // 앞선 = top + fall × (0.76 + 0.3 + 0.18 이하) + 손가락(±35) 이라 넉넉히 1.3배 + 50
    const float vt = 900.0, k = 2.5;
    float tau = c1.x;
    float fall = vt * (tau - (1.0 - exp(-k * tau)) / k);
    float bottom = min(c0.w, c0.z + fall * 1.3 + 50.0);
    CurtainOut o;
    o.pos = toClip(float2(mix(c0.x - 90.0, c0.y + 90.0, c.x), mix(max(c0.z, c2.y) - 8.0, bottom, c.y)), u);
    o.idx = iid;
    return o;
}

/// 수막 양끝: 넓은 구간에 걸쳐 부드럽게 사라진다
inline float curtainSideMask(float x, float x0, float x1, float tau) {
    float spread = 20.0 + 50.0 * saturate(tau * 0.8);
    float inner = min(60.0, (x1 - x0) * 0.3);
    return smoothstep(x0 - spread, x0 + inner, x) * (1.0 - smoothstep(x1 - inner, x1 + spread, x));
}

/// 수막에서 x(세로줄)에만 달린 값들. 두께를 한 픽셀에서 세 번(제자리, 오른쪽, 아래) 재는데,
/// 제자리와 아래는 같은 세로줄이라 노이즈를 다시 뽑지 않고 나눠 쓴다
struct CurtainCol {
    float xm;           // 양끝 마스크
    float var_;         // 떨어진 거리 변화
    float fingN;        // 손가락 노이즈
    float front;        // 앞선 y
    float shift[4];     // 앞선 복사본들의 일그러짐
    float ci;           // 세로 물줄기 칸
    float2 th;
    float present;
};

inline CurtainCol curtainCol(float x, float4 c0, float4 c1) {
    float tau = c1.x, seed = c1.w;
    const float vt = 900.0, k = 2.5;
    float fall = vt * (tau - (1.0 - exp(-k * tau)) / k);
    CurtainCol c;
    c.xm = curtainSideMask(x, c0.x, c0.y, tau);
    c.var_ = 0.76 + 0.3 * vnoise1(x * 0.011 + seed) + 0.18 * vnoise1(x * 0.03 + seed * 2.3);
    c.fingN = vnoise1(x * 0.05 + seed * 1.7);
    float fing = (c.fingN - 0.5) * min(1.0, tau * 1.2) * 70.0;
    c.front = c0.z + fall * c.var_ * mix(0.8, 1.0, c.xm) + fing;
    for (int e = 1; e <= 4; e++) {
        float fe = float(e);
        c.shift[e - 1] = (vnoise1(x * 0.03 + seed + fe * 3.7) - 0.5) * 8.0 * fe;
    }
    const float cellW = 26.0;
    c.ci = floor(x / cellW);
    c.th = hash22(float2(c.ci, seed));
    c.present = step(0.64, hash12(float2(c.ci * 1.3, seed + 2.0))) * (0.5 + c.fingN);
    return c;
}

inline float curtainThickness(float2 g, thread const CurtainCol& col, float4 c0, float4 c1, float clipTop) {
    if (g.y < clipTop) return 0.0;
    float tau = c1.x, str = c1.y;
    float top = c0.z;
    const float vt = 900.0, k = 2.5;
    float fall = vt * (tau - (1.0 - exp(-k * tau)) / k);
    float xm = col.xm;
    if (xm <= 0.0) return 0.0;
    float rel = col.front - g.y;             // 앞선에서 위쪽으로의 거리
    if (rel < 0.0) return 0.0;
    float strc = min(str, 1.2);
    float headLen = 9.0 + 14.0 * str;
    float hr = rel / headLen;
    float head = exp(-hr * hr) * (0.42 + 0.3 * min(str, 1.0));
    // 앞선 복사본: 앞선이 멈칫멈칫 내려가며 남긴 옛 앞선 자국. 같은 모양을 따르되 조금씩 일그러지고,
    // 위로 갈수록 간격이 벌어지고 옅어진다
    float spacing = 22.0 + 26.0 * tau;
    float echoes = 0.0;
    for (int e = 1; e <= 4; e++) {
        float fe = float(e);
        float c = spacing * fe * (1.0 + 0.15 * fe) + col.shift[e - 1];
        float d = (rel - c) / (1.8 + 0.5 * fe);
        echoes += exp(-d * d) * 0.3 * exp(-0.5 * fe);
    }
    echoes *= exp(-tau * 0.5) * strc;
    // 앞선이 지나간 자리에 남는 가는 세로 물줄기: 드문드문, 살짝 구불거리고 알갱이지며 위로 갈수록 흐려진다
    const float cellW = 26.0;
    float ci = col.ci;
    float2 th = col.th;
    float tx = (ci + 0.2 + 0.6 * th.x) * cellW + (vnoise1(g.y * 0.02 + ci * 1.7) - 0.5) * 3.0;
    float td = (g.x - tx) / mix(0.8, 1.8, th.y);
    float trail = exp(-td * td) * col.present * 0.28 * strc * exp(-tau * 0.45)
                * smoothstep(headLen, headLen * 2.5, rel) * smoothstep(0.0, 90.0, g.y - top)
                * (0.6 + 0.4 * vnoise1(g.y * 0.05 + ci));
    // 얇은 잔여 막
    float tailTop = top + fall * 0.35 * col.var_;
    float film = 0.12 * str * exp(-tau * 0.9) * smoothstep(tailTop - 30.0, tailTop + 60.0, g.y);
    // 두께는 양끝에서 살짝만 줄이고(모양), 실제 사라짐은 조각 셰이더에서 투명도로 처리
    // 맨 위 시작 지점은 칼같이 자르지 않고 40pt에 걸쳐 서서히 나타난다
    return (head + echoes + trail + film) * sqrt(xm) * smoothstep(clipTop, clipTop + 40.0, g.y);
}

fragment float4 curtainFragment(CurtainOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                const device float4* cs [[buffer(1)]],
                                texture2d<float> mask [[texture(0)]]) {
    float4 c0 = cs[in.idx * 3], c1 = cs[in.idx * 3 + 1], c2 = cs[in.idx * 3 + 2];
    if (!visibleFor(c1.z, in.pos, mask, u)) discard_fragment();
    float2 g = worldOf(in.pos, u);
    CurtainCol cc = curtainCol(g.x, c0, c1);
    float T = curtainThickness(g, cc, c0, c1, c2.y);
    if (T < 0.02) discard_fragment();
    const float e = 0.75;
    CurtainCol colR = curtainCol(g.x + e, c0, c1);
    float tx = curtainThickness(g + float2(e, 0.0), colR, c0, c1, c2.y);
    float ty = curtainThickness(g + float2(0.0, e), cc, c0, c1, c2.y);
    float2 grad = float2(tx - T, ty - T) / e;
    float rel = cc.front - g.y;             // 앞선에서 위쪽으로의 거리
    float headLen = 9.0 + 14.0 * c1.y;
    float headness = exp(-pow(rel / (headLen * 2.2), 2.0));
    float fade = 1.0 - smoothstep(c2.x - 1.2, c2.x, c1.x);
    float side = smoothstep(0.0, 1.0, cc.xm);
    // 앞선(본진): 물방울과 같은 선명한 빛. 기울기를 적당히 눌러 하이라이트가 가파른 가장자리 쪽에 얇게만 맺히게 한다
    float headCover = smoothstep(0.02, 0.12, T) * fade * side;
    float4 headCol = shadeDrop(-grad * 4.5, T, headCover, in.pos, u);
    // 하이라이트 둘레의 연한 어두운 테두리 (밝은 배경에서도 하이라이트가 드러나게)
    if (int(u.water.w + 0.5) != 3) {
        headCol = underDark(headCol, min(1.0, highlightShadow(-grad * 4.5, u) * 1.3) * headCover * (0.42 + 0.4 * u.light.w));
    }
    // 위쪽 자국(앞선 복사본, 세로선, 잔여 막): 은은하게
    // 위쪽 자국: 기울기에 상한을 둬서 비탈이 어두워지지 않게
    float2 nt = -grad * 3.5;
    nt *= min(1.0, 0.65 / max(length(nt), 1e-4));
    float4 trailCol = shadeWater(nt, float2(0.0, 1.0), T, smoothstep(0.02, 0.14, T) * fade * 0.7 * side,
                                 40.0, 0.2, in.pos, u);
    // 개발용: 1 = 앞선만, 2 = 자국만, 3 = 테두리 고리 없이, 4 = 섞임 비율 시각화
    int dbg = int(u.water.w + 0.5);
    if (dbg == 1) return headCol;
    if (dbg == 2) return trailCol;
    if (dbg == 4) return float4(headness, 0, 1.0 - headness, 1) * headCover;
    float4 col = mix(trailCol, headCol, headness);
    // 물빛 막: 수막 전체에 중간 밝기의 푸른 회색을 넓게 깔고, 하이라이트 주변만 걷어낸다.
    // 밝은 배경에서는 막 덕분에 하이라이트가 상대적으로 빛나 보이고, 어두운 배경에서는 배경과 밝기가 비슷해 거의 티가 안 난다
    float2 nh = -grad * 4.5;
    float clear = smoothstep(0.06, 0.45, specGlow(nh, u, 24.0));
    float tintA = mix(0.05, 0.12, headness) * smoothstep(0.02, 0.2, T) * fade * side * (1.0 - clear);
    return underTint(col, float3(0.45, 0.53, 0.63), tintA);
}

// ---------- 마우스로 누른 물 (유리와 랩 사이에 낀 물이 눌려 퍼짐) ----------
// 무리 하나 = 본 방울 + 거기서 튀어 나간 잔 물방울. 무리마다 3개:
// p0 = (x, y, 반경, 알파), p1 = (늘어남 e·cos2φ, e·sin2φ, 잔 물방울 시작 번호, 개수),
// p2 = (그릴 반경(그림자 몫 포함), 합치는 거리 k, 그림자 진하기, 그림자 퍼짐)
// 잔 물방울은 (x, y, 반경, 0).
// 본 방울 윤곽은 항상 매끈한 원·타원이다. φ 방향으로 (1+e)배, 수직으로 1/(1+e)배 늘여 넓이(물의 양)를 유지한다.
// (cos2θ 같은 윤곽 모드로 늘이면 크게 늘어날 때 땅콩 모양으로 파이므로 진짜 타원을 쓴다)
// 잔 물방울과는 부드러운 합집합(smin)으로 합쳐서, 가까우면 목으로 이어지고 멀어지면 목이 가늘어지다 끊긴다.

struct PressOut {
    float4 pos [[position]];
    uint idx [[flat]];
};

vertex PressOut pressVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            constant Uniforms& u [[buffer(0)]], const device float4* ps [[buffer(1)]]) {
    float4 p0 = ps[iid * 3], p2 = ps[iid * 3 + 2];
    float2 c = quadCorner(vid);
    PressOut o;
    o.pos = toClip(p0.xy + (c * 2.0 - 1.0) * p2.x, u);
    o.idx = iid;
    return o;
}

/// 본 방울(타원)까지의 부호 거리 근사 (안쪽 음수): (k − 1) / |∇k|
inline float pressEllipseSD(float2 g, float4 p0, float4 p1) {
    float R = p0.z;
    if (R < 0.3) return 1e4;
    // 늘어나는 축 (cosφ, sinφ): (1 + cos2φ, sin2φ)를 정규화 (반각 공식)
    float e = length(p1.xy);
    float2 hv = float2(p1.x + e, p1.y);
    float2 ax = dot(hv, hv) > 1e-10 ? normalize(hv) : float2(0.0, 1.0);
    float2 d = g - p0.xy;
    float2 ab = R * float2(1.0 + e, 1.0 / (1.0 + e));
    float2 qa = float2(dot(d, ax), dot(d, float2(-ax.y, ax.x))) / ab;
    float k = length(qa);
    float2 gq = qa / ab / max(k, 1e-5);
    return (k - 1.0) / max(length(gq), 1e-5);
}

inline float pressSmin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

/// 무리 전체의 부호 거리
inline float pressUnion(float2 g, float4 p0, float4 p1, float k, const device float4* ps) {
    float d = pressEllipseSD(g, p0, p1);
    int start = int(p1.z), n = int(p1.w);
    for (int i = 0; i < n; i++) {
        float4 m = ps[start + i];
        d = pressSmin(d, length(g - m.xy) - m.z, k);
    }
    return d;
}

fragment float4 pressFragment(PressOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                              const device float4* ps [[buffer(1)]]) {
    float4 p0 = ps[in.idx * 3], p1 = ps[in.idx * 3 + 1], p2 = ps[in.idx * 3 + 2];
    float2 g = worldOf(in.pos, u);
    float k = p2.y;
    float s = pressUnion(g, p0, p1, k, ps);
    float px = 1.0 / u.timeInfo.y;
    float cover = 1.0 - smoothstep(-px * 0.7, px * 0.7, s);
    if (cover <= 0.001) discard_fragment();
    const float e = 0.5;
    float2 grad = float2(pressUnion(g + float2(e, 0.0), p0, p1, k, ps) - pressUnion(g - float2(e, 0.0), p0, p1, k, ps),
                         pressUnion(g + float2(0.0, e), p0, p1, k, ps) - pressUnion(g - float2(0.0, e), p0, p1, k, ps));
    float2 nO = grad / max(length(grad), 1e-5);          // 바깥 방향 법선

    // 메니스커스 폭은 가까운 쪽 크기를 따른다: 본 방울은 가장자리만 둥근 평평한 물, 잔 물방울은 전체가 둥근 방울
    float dm = pressEllipseSD(g, p0, p1);
    float wm = exp(-max(dm, 0.0) / 3.0);
    float wsum = wm, wacc = wm * clamp(p0.z * 0.2, 2.0, 8.0);
    int start = int(p1.z), n = int(p1.w);
    for (int i = 0; i < n; i++) {
        float4 m = ps[start + i];
        float wt = exp(-max(length(g - m.xy) - m.z, 0.0) / 3.0);
        wsum += wt;
        wacc += wt * clamp(m.z * 0.9, 0.8, 8.0);
    }
    float w = wacc / max(wsum, 1e-5);
    cover *= mix(1.0, p0.w, wm / max(wsum, 1e-5));      // 본 방울이 아주 작아질 때만 옅어짐

    float v = saturate(1.0 + s / w);                    // 0 안쪽 평평한 곳 → 1 윤곽
    float2 n2 = nO * v * 0.92;
    float4 col = shadeDrop(n2, 0.2, cover, in.pos, u);
    col = underDark(col, min(1.0, highlightShadow(n2, u) * 1.3) * cover * (0.42 + 0.4 * u.light.w));
    float clear = smoothstep(0.06, 0.45, specGlow(n2, u, 24.0));
    col = underTint(col, float3(0.45, 0.53, 0.63), 0.07 * cover * (1.0 - clear));
    return col;
}

/// 누른 물방울 밑에 까는 은은한 그림자 (밝은 배경에서도 보이게). 윤곽 바깥쪽에만, 아래로 살짝 비껴서 넓고 부드럽게.
/// 번지는 폭과 진하기는 가까운 방울 크기를 따른다 (작은 잔 물방울까지 똑같이 넓게 번지면 후광처럼 보인다).
/// 유리 모드에서는 이것만 유리 밑에 그린다 (유리가 가장자리에서 이걸 살짝 굴절시켜 윤곽도 또렷해진다)
fragment float4 pressShadowFragment(PressOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                    const device float4* ps [[buffer(1)]]) {
    float4 p0 = ps[in.idx * 3], p1 = ps[in.idx * 3 + 1], p2 = ps[in.idx * 3 + 2];
    float2 g = worldOf(in.pos, u);
    float k = p2.y;
    const float2 offset = float2(0.0, 4.0);
    float2 q = g - offset;
    // 가까운 방울 크기 (거리 가중 평균)
    float dm = pressEllipseSD(q, p0, p1);
    float wt = exp(-max(dm, 0.0) / 6.0), wsum = wt, size = wt * p0.z;
    float wMain = wt;
    int start = int(p1.z), n = int(p1.w);
    for (int i = 0; i < n; i++) {
        float4 m = ps[start + i];
        float w = exp(-max(length(q - m.xy) - m.z, 0.0) / 6.0);
        wsum += w;
        size += w * m.z;
    }
    size /= max(wsum, 1e-5);
    float blur = clamp(size * 0.52 * p2.w, 3.0, 21.0 * p2.w);
    float sd = pressUnion(q, p0, p1, k, ps);
    float t = 1.0 - smoothstep(-blur * 0.5, blur * 1.5, sd);
    float a = t * t * mix(0.35, 1.0, smoothstep(3.0, 20.0, size)) * p2.z;
    a *= mix(1.0, p0.w, wMain / max(wsum, 1e-5));                // 본 방울이 옅어지면 그 그림자도
    a *= smoothstep(-1.0, 2.5, pressUnion(g, p0, p1, k, ps));     // 물방울 안쪽은 비움
    if (a < 0.002) discard_fragment();
    return float4(0.0, 0.0, 0.0, a);
}
"""#
