// 맥판 Shaders.swift(MSL)를 HLSL로 옮긴 것. 런타임에 D3DCompile로 컴파일한다.
// 좌표계: 가상 화면 좌상단 원점, y 아래 방향, 단위 pt (= 물리 픽셀 / 배율).

struct Uniforms {
    float4 screen;    // originX, originY, width, height (pt)
    float4 timeInfo;  // time, scale(px/pt), cornerRadius, poolCapacity
    float4 rain;      // 0, wind(dx/dy), speedMul, lengthMul
    float4 rain2;     // widthMul, opacity, depthStep, depthOfField
    float4 rainColor; // rgb, desktopVisibility
    float4 light;     // dirX, dirY (빛이 오는 방향), specular, rimDark
    float4 water;     // 0, 0, tint, debugShade
    float4 counts;    // edgeCount, edgeLength, screenIndex, cornerExponent
    float4 glass;     // 굴절 세기, 흐림(pt), 밝은 배경에서 보이기, 어두운 배경에서 보이기
};
cbuffer UB : register(b0) { Uniforms u; };

Texture2D<float2> maskTex : register(t0);
StructuredBuffer<float4> items : register(t1);
StructuredBuffer<float> heights : register(t2);
Texture2D<float4> deskTex : register(t3);        // 유리 물방울: 비 창을 뺀 화면 (Desktop Duplication)
SamplerState linearClamp : register(s0);

// ---------- 유틸 ----------

uint pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
float rnd(uint v) { return float(pcg(v)) * (1.0 / 4294967296.0); }

float sq(float x) { return x * x; }
float hash11(float p) { p = frac(p * 0.1031); p *= p + 33.33; p *= p + p; return frac(p); }
float hash12(float2 p) {
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}
float2 hash22(float2 p) {
    float3 p3 = frac(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.xx + p3.yz) * p3.zy);
}
float vnoise1(float x) {
    float i = floor(x), f = frac(x);
    float uu = f * f * (3.0 - 2.0 * f);
    return lerp(hash11(i), hash11(i + 1.0), uu);
}
float vnoise(float2 p) {
    float2 i = floor(p), f = frac(p);
    float2 uu = f * f * (3.0 - 2.0 * f);
    float a = hash12(i), b = hash12(i + float2(1, 0)), c = hash12(i + float2(0, 1)), d = hash12(i + float2(1, 1));
    return lerp(lerp(a, b, uu.x), lerp(c, d, uu.x), uu.y);
}

float4 toClip(float2 g) {
    float2 l = (g - u.screen.xy) / u.screen.zw;
    return float4(l.x * 2.0 - 1.0, 1.0 - l.y * 2.0, 0.0, 1.0);
}

float2 worldOf(float4 pos) { return pos.xy / u.timeInfo.y + u.screen.xy; }

/// 해당 픽셀을 덮고 있는 가장 앞 창의 순위. r = 전역 순위, g = 이 모니터 안에서의 순위 (255 = 바탕화면)
float2 maskRanks(float4 pos) {
    uint w, h;
    maskTex.GetDimensions(w, h);
    uint2 c = min(uint2(pos.xy), uint2(w - 1, h - 1));
    return maskTex.Load(int3(c, 0)) * 255.0;
}
float2 quadCorner(uint vid) { return float2(float(vid & 1u), float(vid >> 1u)); }

// 순위 + 소속 모니터 인코딩 (rank + 256 * screen)
float decodeScreen(float enc) { return floor(enc / 256.0 + 0.001); }
float decodeRank(float enc) { return enc - decodeScreen(enc) * 256.0; }
/// 이 모니터 소속이고, 앞 창에 가려지지 않았는지
bool visibleFor(float enc, float4 pos) {
    if (abs(decodeScreen(enc) - u.counts.z) > 0.5) return false;
    return maskRanks(pos).x >= decodeRank(enc) - 0.5;
}

/// 창 모서리를 초타원으로 근사한 거리. d: 점 − 모서리 중심, E: 곡선 길이, n: 지수(2 = 원)
float cornerDist(float2 d, float E, float n, out float2 nrm) {
    float2 a = max(abs(d) / E, float2(1e-4, 1e-4));
    float2 an = pow(a, float2(n, n));
    float sum = an.x + an.y;
    float L = pow(sum, 1.0 / n);
    float2 grad = pow(a, float2(n - 1.0, n - 1.0)) * pow(sum, 1.0 / n - 1.0);
    float gl = max(length(grad), 1e-3);
    float2 sg = float2(d.x < 0.0 ? -1.0 : 1.0, d.y < 0.0 ? -1.0 : 1.0);
    nrm = normalize(grad * sg);
    return (L - 1.0) * E / gl;
}

// ---------- 물 셰이딩 ----------

/// 물방울(낙수, 튀김)용 셰이딩. 공 모양이라 평행광 하나로 충분하다.
float4 shadeDrop(float2 n2, float thick, float cover, float rimStart, float rimMul) {
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
    return float4(min(col, a.xxx), a);
}

/// 화면 왼쪽 위(빛 방향) 바깥에 있는 광원. 가까운 곳은 밝고 멀어질수록(오른쪽 아래로) 어두워진다.
float2 lightAt(float2 g, out float falloff) {
    float2 c = u.screen.xy + u.screen.zw * 0.5;
    float diag = length(u.screen.zw);
    float2 P = c + normalize(u.light.xy) * diag * 0.9;
    float2 d = P - g;
    float dist = length(d);
    float k = dist / (0.7 * diag);
    falloff = 1.3 / (1.0 + k * k);
    return d / max(dist, 1e-3);
}

/// shadeDrop과 같은 빛에서 하이라이트 주변이 얼마나 빛을 받는지 (지수가 낮을수록 넓게)
float specGlow(float2 n2, float expo) {
    float l2 = dot(n2, n2);
    if (l2 > 0.97) n2 *= rsqrt(l2) * 0.985;
    float3 n = float3(n2, sqrt(max(1.0 - dot(n2, n2), 0.0)));
    float3 H = normalize(normalize(float3(u.light.x, u.light.y, 0.9)) + float3(0, 0, 1));
    return pow(saturate(dot(n, H)), expo);
}

/// 프리멀티플라이드 색 col 아래에 색 막을 깐다
float4 underTint(float4 col, float3 tint, float alpha) {
    return col + (1.0 - col.a) * float4(tint * alpha, alpha);
}

/// shadeDrop 하이라이트 옆에 평행하게 붙는 어두운 선 (0..1). 밝은 배경에서 흰 하이라이트가 묻히지 않게 쓴다.
float highlightShadow(float2 n2) {
    float l2 = dot(n2, n2);
    if (l2 > 0.97) n2 *= rsqrt(l2) * 0.985;
    float3 n = float3(n2, sqrt(max(1.0 - dot(n2, n2), 0.0)));
    float3 H = normalize(normalize(float3(u.light.x, u.light.y, 0.9)) + float3(0, 0, 1));
    float2 ld = normalize(u.light.xy);
    float3 Hs = normalize(H - float3(ld * 0.09, 0.0));
    float s = pow(saturate(dot(n, H)), 260.0);
    float ss = pow(saturate(dot(n, Hs)), 260.0);
    return saturate(ss - s);
}

/// 띠·막대 모양 물(윗변, 옆 물줄기, 수막)용 셰이딩. axis: 물이 휘는 방향, featurePx: 물의 픽셀 폭
float4 shadeWater(float2 n2, float2 axis, float thick, float cover, float featurePx, float lineDark, float4 pos) {
    float aa = smoothstep(2.0, 9.0, featurePx);
    n2 *= lerp(0.45, 1.0, aa);
    float l2 = dot(n2, n2);
    if (l2 > 0.97) n2 *= rsqrt(l2) * 0.985;
    float3 n = float3(n2, sqrt(max(1.0 - dot(n2, n2), 0.0)));
    float fall;
    float2 ld = lightAt(worldOf(pos), fall);
    float3 L = normalize(float3(ld, 0.75));
    float3 H = normalize(L + float3(0, 0, 1));
    float axisAtt = 1.0;
    if (dot(axis, axis) > 0.25) {
        H = normalize(float3(dot(H.xy, axis) * axis, H.z));
        axisAtt = lerp(0.55, 1.0, abs(dot(ld, axis)));
    }
    float ndh = saturate(dot(n, H));
    float expo = lerp(20.0, 80.0, aa);
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
    return float4(min(col, a.xxx), a);
}

/// 프리멀티플라이드 색 col 아래에 어두운 선을 깐다 (흰 하이라이트 밑의 어두운 선)
float4 underDark(float4 col, float dk) {
    return col + (1.0 - col.a) * float4(0.06, 0.07, 0.09, 1.0) * dk;
}

// ---------- 가려짐 마스크 ----------
// items: [rect(x, y, w, h), (전역 순위, 모니터 내 순위, 모서리 반경, 0)] × n

struct MaskOut {
    float4 pos : SV_Position;
    float2 local : TEXCOORD0;
    nointerpolation float2 halfSize : TEXCOORD1;
    nointerpolation float2 value : TEXCOORD2;
    nointerpolation float radius : TEXCOORD3;
};

MaskOut maskVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float4 r = items[iid * 2];
    float4 m = items[iid * 2 + 1];
    float2 c = quadCorner(vid);
    MaskOut o;
    o.pos = toClip(r.xy + c * r.zw);
    o.local = (c - 0.5) * r.zw;
    o.halfSize = r.zw * 0.5;
    o.value = min(m.xy, float2(254.0, 254.0)) / 255.0;
    o.radius = m.z;
    return o;
}

float2 maskFragment(MaskOut i) : SV_Target {
    float E = min(i.radius, min(i.halfSize.x, i.halfSize.y));
    if (E > 0.5) {
        float2 q = abs(i.local) - (i.halfSize - E);
        if (q.x > 0.0 && q.y > 0.0) {
            float2 nn;
            if (cornerDist(q, E, u.counts.w, nn) > 0.0) discard;
        }
    }
    return i.value;
}

// ---------- 빗줄기 (상태 없음: 인스턴스 번호와 시간만으로 계산) ----------

struct RainOut {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
    nointerpolation float depth : TEXCOORD1;
    nointerpolation float alpha : TEXCOORD2;
    nointerpolation float side : TEXCOORD3;
};

RainOut rainVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float W = u.screen.z, H = u.screen.w;
    float t = u.timeInfo.x;
    float d = rnd(iid * 7u + 1u);            // 0 가까움 .. 1 멀리
    float near_ = 1.0 - d;
    float persp = lerp(0.45, 1.7, near_ * near_);
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
    float blur = u.rain2.w * near_ * near_;
    float width = (0.7 + 0.9 * near_ + 2.4 * blur) * u.rain2.x;
    float px = 1.0 / u.timeInfo.y;
    float hw = width * 0.5 + px;
    float2 c = quadCorner(vid);
    float2 local = float2(xHead, yHead) - dir * len * (1.0 - c.y) + perp * hw * (c.x * 2.0 - 1.0);

    RainOut o;
    o.pos = toClip(local + u.screen.xy);
    o.uv = float2(c.y, (c.x * 2.0 - 1.0) * hw / (width * 0.5));
    o.depth = d;
    o.alpha = u.rain2.y * lerp(0.35, 1.0, near_) / (1.0 + 2.0 * blur) * (0.6 + 0.4 * rnd(cs + 11u));
    o.side = dot(perp, u.light.xy) >= 0.0 ? 1.0 : -1.0;
    return o;
}

float4 rainFragment(RainOut i) : SV_Target {
    float2 ranks = maskRanks(i.pos);
    float rank = ranks.y;                    // 이 모니터 안에서의 순위
    if (rank < 0.5) discard;                 // 각 모니터의 맨 위 창(과 작업 표시줄·메뉴)에는 비가 보이지 않음
    bool desktop = ranks.x > 254.5;
    float w = desktop ? 1.0 : saturate(rank * u.rain2.z);
    float vis = smoothstep(i.depth - 0.05, i.depth + 0.05, w);
    if (desktop) vis *= u.rainColor.w;
    if (vis < 0.002) discard;
    float s = i.uv.y;
    float core = exp(-s * s * 2.5);
    float hs = s - i.side * 0.45;
    float hl = exp(-hs * hs * 6.0);
    float along = smoothstep(0.0, 0.45, i.uv.x) * smoothstep(1.0, 0.86, i.uv.x);
    float a = (core * 0.45 + hl * 0.55) * along * i.alpha * vis;
    float3 col = u.rainColor.rgb * (0.8 + 0.5 * hl);
    return float4(min(col * a, a.xxx), a);
}

// ---------- 물방울 (낙수, 튀는 물) ----------

struct DropOut {
    float4 pos : SV_Position;
    float2 local : TEXCOORD0;
    nointerpolation float r : TEXCOORD1;
    nointerpolation float stretch : TEXCOORD2;
    nointerpolation float2 dir : TEXCOORD3;
    nointerpolation float rank : TEXCOORD4;
    nointerpolation float alpha : TEXCOORD5;
    nointerpolation float light : TEXCOORD6;     // 1 = 튀김: 연하게 그림
};

DropOut makeDrop(uint vid, float2 center, float r, float2 dir, float stretch, float rank, float alpha) {
    float px = 1.5 / u.timeInfo.y;
    float2 perp = float2(-dir.y, dir.x);
    float2 c = quadCorner(vid);
    float across = lerp(-r - px, r + px, c.x);
    float along = lerp(-r * stretch - px, r + px, c.y);
    DropOut o;
    o.pos = toClip(center + perp * across + dir * along);
    o.local = float2(across, along);
    o.r = r; o.stretch = stretch; o.dir = dir; o.rank = rank; o.alpha = abs(alpha);
    o.light = alpha < 0.0 ? 1.0 : 0.0;
    return o;
}

DropOut dropVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float4 a = items[iid * 2], b = items[iid * 2 + 1];
    return makeDrop(vid, a.xy, a.z, b.xy, b.z, b.w, a.w);
}

/// 빗방울이 창 윗변과 화면 바닥에 부딪혀 튀는 물. 역시 상태 없이 GPU에서 계산.
/// items: [(x0, x1, y, rank), (누적 길이, 가중치, 0, 0)] × edgeCount
DropOut splashVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    uint k = iid / 5u, j = iid % 5u;
    float period = 0.55, life = 0.36;
    float ph = u.timeInfo.x / period + rnd(k * 13u + 1u);
    float cyc = floor(ph);
    float tau = (ph - cyc) * period;
    uint seed = pcg(k * 13u + 7u + uint(int(cyc)) * 2246822519u);
    int ne = int(u.counts.x);
    float s = rnd(seed) * u.counts.y;
    int e = 0;
    for (int n = 1; n < ne; n++) { if (items[n * 2 + 1].x <= s) e = n; }
    float4 ed = items[e * 2];
    float4 em = items[e * 2 + 1];
    float x = ed.x + (s - em.x) / max(em.y, 0.01);
    float ang = (rnd(seed + j * 7919u) - 0.5) * 2.4;
    float sp = lerp(60.0, 180.0, rnd(seed + j * 104729u)) * (j == 0u ? 0.5 : 1.0);
    float2 v0 = float2(sin(ang), -cos(ang)) * sp + float2(u.rain.y * 60.0, 0.0);
    float2 p = float2(x, ed.z) + v0 * tau + float2(0.0, 800.0 * tau * tau);
    float2 v = v0 + float2(0.0, 1600.0 * tau);
    float spd = length(v);
    float r = lerp(0.8, 1.8, rnd(seed + j * 31337u));
    // 약 65%는 꼭대기를 지나 떨어지기 시작하면 곧 사라진다 (떨어지는 방울이 너무 많아 보이지 않게)
    float apex = max(-v0.y, 0.0) / 1600.0;
    float myLife = rnd(seed + j * 7717u) < 0.65 ? min(life, apex + lerp(0.03, 0.08, rnd(seed + j * 5153u))) : life;
    float alive = tau < myLife ? 1.0 - tau / myLife : 0.0;
    DropOut o = makeDrop(vid, p, r, v / max(spd, 1.0), 1.0 + min(2.0, spd * 0.004), ed.w, -alive);
    if (alive <= 0.0) o.pos = float4(0.0, 0.0, 0.0, 0.0);
    return o;
}

float4 dropFragment(DropOut i) : SV_Target {
    if (!visibleFor(i.rank, i.pos)) discard;
    float r = i.r;
    float2 l = i.local;
    float qy = l.y > 0.0 ? l.y / r : l.y / (r * i.stretch);
    float qx = l.x / r;
    if (l.y < 0.0) qx /= lerp(1.0, 0.6, saturate(-qy));   // 꼬리 쪽은 가늘게 (눈물방울 모양)
    float d = length(float2(qx, qy));
    float aa = (1.0 / u.timeInfo.y) / r;
    float cover = (1.0 - smoothstep(1.0 - aa, 1.0 + aa, d)) * i.alpha;
    if (cover <= 0.001) discard;
    float2 nl = float2(qx, qy) * (d > 0.985 ? 0.985 / d : 1.0);
    float2 perp = float2(-i.dir.y, i.dir.x);
    float2 n2 = perp * nl.x + i.dir * nl.y;
    // 튀김은 테두리가 진해 보이지 않게 연하게
    if (i.light > 0.5) { n2 *= 0.8; cover *= 0.85; }
    return shadeDrop(n2, saturate(r / 4.0), cover, 0.06, 1.0);
}

// ---------- 창 윗변에 고인 물 + 위쪽 둥근 모서리 ----------
// 고인 물과 옆면 물줄기는 둘 다 "창 외곽선(둥근 사각형)으로부터 바깥쪽 거리"로 그린다.
// items: 풀당 4개. heights: 높이장

struct IdxOut {
    float4 pos : SV_Position;
    nointerpolation uint idx : TEXCOORD0;
};

IdxOut poolVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float4 a = items[iid * 4], b = items[iid * 4 + 1], c3 = items[iid * 4 + 2];
    float R = c3.z;
    float maxT = c3.w * max(b.w, 1.0) + 4.0;
    float2 c = quadCorner(vid);
    float x = lerp(a.x - maxT - 2.0, a.x + a.z + maxT + 2.0, c.x);
    float y = lerp(a.y - maxT - 2.0, a.y + max(R, maxT) + 1.0, c.y);
    IdxOut o;
    o.pos = toClip(float2(x, y));
    o.idx = iid;
    return o;
}

float catmull(float p0, float p1, float p2, float p3, float t) {
    float t2 = t * t, t3 = t2 * t;
    return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3);
}
float catmullD(float p0, float p1, float p2, float p3, float t) {
    return 0.5 * ((-p0 + p2) + 2.0 * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t + 3.0 * (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t * t);
}

/// 높이장을 부드럽게 샘플링: 높이와 기울기(dh/dx)
float2 sampleHeights(int off, int n, float dx, float x) {
    float ft = x / dx - 0.5;
    float fl = floor(ft);
    int i0 = clamp(int(fl), 0, n - 1);
    int i1 = min(i0 + 1, n - 1);
    int im = max(i0 - 1, 0), ip = min(i1 + 1, n - 1);
    float fr = saturate(ft - fl);
    float p0 = heights[off + im], p1 = heights[off + i0], p2 = heights[off + i1], p3 = heights[off + ip];
    return float2(max(catmull(p0, p1, p2, p3, fr), 0.0), catmullD(p0, p1, p2, p3, fr) / dx);
}

float4 poolFragment(IdxOut i) : SV_Target {
    float4 a = items[i.idx * 4], b = items[i.idx * 4 + 1], c3 = items[i.idx * 4 + 2], c4 = items[i.idx * 4 + 3];
    if (!visibleFor(a.w, i.pos)) discard;
    float2 g = worldOf(i.pos);
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
    float reach = 0.0;                    // 물줄기 머리가 이 모서리 곡선을 돈 정도
    if (lp.x < R || lp.x > width - R) {
        bool left = lp.x < R;
        float2 C = float2(left ? R : width - R, R);
        float2 d = lp - C;
        if (d.y > 0.0) discard;                              // 옆면 영역은 물줄기 셰이더 담당
        dist = cornerDist(d, R, u.counts.w, nO);
        theta = saturate(atan2(abs(nO.x), -nO.y) / 1.5707963);
        xs = lp.x - nO.x * dist;
        join = left ? c3.x : c3.y;
        reach = left ? c4.x : c4.y;
    } else {
        if (lp.x < 0.0 || lp.x > width) discard;           // 모서리 반경이 0일 때
        nO = float2(0.0, -1.0);
        dist = -lp.y;
        xs = lp.x;
    }
    if (dist < -px) discard;

    float2 hs = sampleHeights(off, n, dx, clamp(xs, 0.0, width));
    // 물결은 과장해서 보여준다: 주변 평균에서 벗어난 만큼을 키운다 (물리는 그대로 두고 그리기만)
    float hAvg = (sampleHeights(off, n, dx, clamp(xs - 18.0, 0.0, width)).x
                + sampleHeights(off, n, dx, clamp(xs + 18.0, 0.0, width)).x + hs.x) / 3.0;
    float dev = clamp(hs.x - hAvg, -1.2, 1.2);
    hs = float2(max(hs.x + dev * 0.5, 0.0), hs.y * lerp(1.5, 1.0, saturate(abs(hs.x - hAvg) / 3.0)));
    float h = hs.x;
    float tt = smoothstep(0.0, 1.0, theta);
    float jf = saturate(join * 4.0);
    jf *= 1.0 - smoothstep(reach - 0.15, reach, theta);
    float t = lerp(h * (1.0 - smoothstep(0.3, 1.0, theta)), lerp(h, join, tt), jf);
    if (t < 0.18) discard;

    float cover = (1.0 - smoothstep(t - px * 0.6, t + px * 0.6, dist)) * smoothstep(-px, 0.0, dist);
    if (cover <= 0.001) discard;
    float v = saturate(dist / t);
    float glintVar = 0.55 + 0.9 * vnoise(float2(xs * 0.035 - time * 0.4, time * 0.25)) + clamp(-hs.y * 3.0, -0.4, 0.4);
    float prof = lerp(-0.4, 0.9, v) * tt * jf;
    float2 tangent = float2(-nO.y, nO.x);
    float shimmer = (vnoise(float2(xs * 0.05 - time * 0.6, time * 0.7)) - 0.5) * 0.4;
    float ripple = (-hs.y * 1.8 + shimmer) * (1.0 - tt) * lerp(0.45, 1.0, v);
    float2 n2 = nO * prof + tangent * clamp(ripple, -0.75, 0.75);
    // 물 몸통 두께: 윗변은 수위 비율, 물줄기로 이어지는 호 끝은 물줄기 셰이더와 같은 값 (폭 / 5).
    // 다르면 이음매에서 물 색 진하기가 툭 바뀐다 (어두운 배경에서 잘 보였다)
    float thickArg = lerp(t / cap, saturate(join / 5.0), tt * jf);
    float4 col = shadeWater(n2, nO, thickArg, cover, t * u.timeInfo.y, 0.3, i.pos);
    // 수면 선: 수면 바로 안쪽에 연한 어두운 선, 그 아래 밝은 반사선
    float topMask = (1.0 - tt) * saturate((t - 1.0) / 1.2);
    float lw = max(0.5, 0.9 * px);
    float dLine = exp(-sq((dist - (t - 0.6)) / lw)) * topMask;
    float fall;
    lightAt(g, fall);
    float bLine = exp(-sq((dist - (t - 1.9)) / (lw * 1.2))) * topMask
                * clamp(glintVar, 0.15, 1.4) * fall * 0.45 * u.light.z;
    col = underDark(col, dLine * cover * (0.12 + 0.25 * u.light.w));
    float bright = min(bLine * cover, 0.9);
    col = bright.xxxx + col * (1.0 - bright);
    return col * smoothstep(0.18, 0.8, t);
}

// ---------- 창 옆면을 타고 흐르는 물줄기 ----------
// r0 = (옆면 x, 윗변 y, 밑변 y, side), r1 = (머리 y, 꼬리 y, 폭, 순위), r2 = (seed, 유량, 모서리 길이 E, 0), r3 = (이음 계수)

IdxOut rivuletVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float4 r0 = items[iid * 4], r1 = items[iid * 4 + 1], r2 = items[iid * 4 + 2];
    float E = r2.z, side = r0.w;
    float m = r1.z * 2.6 + 3.0;
    bool reached = r1.x >= r0.z - E - 0.5;
    float inward = E + m;
    float xa = side < 0.0 ? r0.x - m : r0.x - inward;
    float xb = side < 0.0 ? r0.x + inward : r0.x + m;
    float2 c = quadCorner(vid);
    float yEnd = reached ? r0.z + m : r1.x + m;
    IdxOut o;
    o.pos = toClip(float2(lerp(xa, xb, c.x), lerp(max(r1.y, r0.y + E) - 1.0, yEnd, c.y)));
    o.idx = iid;
    return o;
}

float4 rivuletFragment(IdxOut i) : SV_Target {
    float4 r0 = items[i.idx * 4], r1 = items[i.idx * 4 + 1], r2 = items[i.idx * 4 + 2], r3 = items[i.idx * 4 + 3];
    if (!visibleFor(r1.w, i.pos)) discard;
    float connect = r3.x;
    float2 g = worldOf(i.pos);
    float edgeX = r0.x, top = r0.y, bottom = r0.z, side = r0.w;
    float tail = r1.y, w = r1.z;
    float seed = r2.x, E = r2.z;
    float start = top + E;
    float sideEnd = bottom - E;
    float head = clamp(r1.x, start, sideEnd);
    bool reached = r1.x >= sideEnd - 0.5;
    if (g.y < start) discard;
    float px = 1.0 / u.timeInfo.y;
    float t = u.timeInfo.x;

    float y = min(g.y, head);
    float ease = smoothstep(start, start + 40.0, y);
    float easeEnd = 1.0 - smoothstep(sideEnd - 30.0, sideEnd, y);
    float wobble = (vnoise1(y * 0.03 + seed) - 0.5) * 0.2 + (vnoise1((y - t * 160.0) * 0.03 + seed * 3.1) - 0.5) * 0.25;
    float wl = w * max(0.7, 1.0 + wobble * ease);
    wl *= lerp(connect, 1.0, ease);
    // 꼬리: 흐름이 멈추면 위에서부터 빠짐. 꼬리가 윗변에 있을 때 빠지는 구간(14pt)이 모서리 곡선 안에서 끝나도록
    // 모서리가 14pt보다 작은 만큼 위로 올린다 (안 그러면 윈도우 창처럼 모서리가 작을 때 곡선 바로 아래 물줄기가
    // 가늘어져 잘려 보인다). 모서리가 14pt 이상이면 전과 같다
    float tl = tail - max(0.0, 14.0 - E);
    wl *= smoothstep(tl, tl + 14.0, g.y);
    float meander = ((vnoise(float2(y * 0.035 - t * 3.2, t * 1.5 + seed)) - 0.5) * 2.0
                   + (vnoise(float2(y * 0.09 - t * 6.0, t * 2.9 + seed * 2.3)) - 0.5) * 0.8) * min(2.6, w * 0.7) * ease * easeEnd;
    if (wl < 0.05) discard;
    float minW = 1.6 * px;
    float thinFade = saturate(wl / minW);
    wl = max(wl, minW);

    float dist;
    float2 nO;
    float capCover = 1.0;
    float along = 0.0;
    if (g.y <= sideEnd || !reached) {
        nO = float2(side, 0.0);
        float inner = min(meander, 0.0);
        dist = (g.x - edgeX) * side - inner;
        wl = meander + wl - inner;
        if (!reached && g.y > head) {
            float hr = wl * 0.8;
            along = (g.y - head) / hr;
            float across = (dist - wl * 0.5) / (wl * 0.5);
            capCover = 1.0 - smoothstep(1.0 - px / hr, 1.0 + px / hr, sqrt(along * along + across * across));
            dist = clamp(dist, 0.0, wl);
        }
    } else {
        float2 C = float2(edgeX - side * E, sideEnd);
        float2 dc = g - C;
        if (dc.x * side < -0.5) discard;
        dist = cornerDist(dc, E, u.counts.w, nO);
        float2 aa = max(abs(dc) / E, float2(1e-4, 1e-4));
        float nh = u.counts.w * 0.5;
        float ang = atan2(pow(aa.y, nh), pow(aa.x, nh));
        const float kDripAngle = 65.0 * 3.14159265 / 180.0;
        float prog = ang / kDripAngle;
        wl *= lerp(1.0, 0.5, saturate(prog));
        capCover = 1.0 - smoothstep(0.93, 1.02, prog);
        float headProg = (r1.x - sideEnd) / (E * kDripAngle);
        capCover *= 1.0 - smoothstep(headProg - 0.2, headProg, prog);
    }
    float cover = (1.0 - smoothstep(wl - px * 0.6, wl + px * 0.6, dist)) * smoothstep(-px, 0.0, dist) * capCover * thinFade;
    if (cover <= 0.001) discard;
    float v = saturate(dist / wl);
    float glint = (vnoise1((y - t * 110.0) * 0.022 + seed) - 0.5) * 0.9 * ease;
    float2 tangent = float2(-nO.y, nO.x);
    float2 n2 = nO * lerp(-0.4, 0.9, v) + tangent * (glint + clamp(along, 0.0, 1.0) * 0.6) * side;
    return shadeWater(n2, nO, saturate(w / 5.0), cover, wl * u.timeInfo.y, 0.3, i.pos);
}

// ---------- 창이 닫힐 때 화면을 타고 흘러내리는 수막 ----------
// items: 수막당 3개

IdxOut curtainVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float4 c0 = items[iid * 3], c1 = items[iid * 3 + 1], c2 = items[iid * 3 + 2];
    float2 c = quadCorner(vid);
    const float vt = 900.0, k = 2.5;
    float tau = c1.x;
    float fall = vt * (tau - (1.0 - exp(-k * tau)) / k);
    float bottom = min(c0.w, c0.z + fall * 1.3 + 50.0);
    IdxOut o;
    o.pos = toClip(float2(lerp(c0.x - 90.0, c0.y + 90.0, c.x), lerp(max(c0.z, c2.y) - 8.0, bottom, c.y)));
    o.idx = iid;
    return o;
}

float curtainSideMask(float x, float x0, float x1, float tau) {
    float spread = 20.0 + 50.0 * saturate(tau * 0.8);
    float inner = min(60.0, (x1 - x0) * 0.3);
    return smoothstep(x0 - spread, x0 + inner, x) * (1.0 - smoothstep(x1 - inner, x1 + spread, x));
}

struct CurtainCol {
    float xm;
    float var_;
    float fingN;
    float front;
    float4 shift;
    float ci;
    float2 th;
    float present;
};

CurtainCol curtainCol(float x, float4 c0, float4 c1) {
    float tau = c1.x, seed = c1.w;
    const float vt = 900.0, k = 2.5;
    float fall = vt * (tau - (1.0 - exp(-k * tau)) / k);
    CurtainCol c;
    c.xm = curtainSideMask(x, c0.x, c0.y, tau);
    c.var_ = 0.76 + 0.3 * vnoise1(x * 0.011 + seed) + 0.18 * vnoise1(x * 0.03 + seed * 2.3);
    c.fingN = vnoise1(x * 0.05 + seed * 1.7);
    float fing = (c.fingN - 0.5) * min(1.0, tau * 1.2) * 70.0;
    c.front = c0.z + fall * c.var_ * lerp(0.8, 1.0, c.xm) + fing;
    [unroll] for (int e = 1; e <= 4; e++) {
        float fe = float(e);
        c.shift[e - 1] = (vnoise1(x * 0.03 + seed + fe * 3.7) - 0.5) * 8.0 * fe;
    }
    const float cellW = 26.0;
    c.ci = floor(x / cellW);
    c.th = hash22(float2(c.ci, seed));
    c.present = step(0.64, hash12(float2(c.ci * 1.3, seed + 2.0))) * (0.5 + c.fingN);
    return c;
}

float curtainThickness(float2 g, CurtainCol col, float4 c0, float4 c1, float clipTop) {
    if (g.y < clipTop) return 0.0;
    float tau = c1.x, str = c1.y;
    float top = c0.z;
    const float vt = 900.0, k = 2.5;
    float fall = vt * (tau - (1.0 - exp(-k * tau)) / k);
    float xm = col.xm;
    if (xm <= 0.0) return 0.0;
    float rel = col.front - g.y;
    if (rel < 0.0) return 0.0;
    float strc = min(str, 1.2);
    float headLen = 9.0 + 14.0 * str;
    float hr = rel / headLen;
    float head = exp(-hr * hr) * (0.42 + 0.3 * min(str, 1.0));
    float spacing = 22.0 + 26.0 * tau;
    float echoes = 0.0;
    [unroll] for (int e = 1; e <= 4; e++) {
        float fe = float(e);
        float c = spacing * fe * (1.0 + 0.15 * fe) + col.shift[e - 1];
        float d = (rel - c) / (1.8 + 0.5 * fe);
        echoes += exp(-d * d) * 0.3 * exp(-0.5 * fe);
    }
    echoes *= exp(-tau * 0.5) * strc;
    const float cellW = 26.0;
    float ci = col.ci;
    float2 th = col.th;
    float tx = (ci + 0.2 + 0.6 * th.x) * cellW + (vnoise1(g.y * 0.02 + ci * 1.7) - 0.5) * 3.0;
    float td = (g.x - tx) / lerp(0.8, 1.8, th.y);
    float trail = exp(-td * td) * col.present * 0.28 * strc * exp(-tau * 0.45)
                * smoothstep(headLen, headLen * 2.5, rel) * smoothstep(0.0, 90.0, g.y - top)
                * (0.6 + 0.4 * vnoise1(g.y * 0.05 + ci));
    float tailTop = top + fall * 0.35 * col.var_;
    float film = 0.12 * str * exp(-tau * 0.9) * smoothstep(tailTop - 30.0, tailTop + 60.0, g.y);
    return (head + echoes + trail + film) * sqrt(xm) * smoothstep(clipTop, clipTop + 40.0, g.y);
}

float4 curtainFragment(IdxOut i) : SV_Target {
    float4 c0 = items[i.idx * 3], c1 = items[i.idx * 3 + 1], c2 = items[i.idx * 3 + 2];
    if (!visibleFor(c1.z, i.pos)) discard;
    float2 g = worldOf(i.pos);
    CurtainCol cc = curtainCol(g.x, c0, c1);
    float T = curtainThickness(g, cc, c0, c1, c2.y);
    if (T < 0.02) discard;
    const float e = 0.75;
    CurtainCol colR = curtainCol(g.x + e, c0, c1);
    float tx = curtainThickness(g + float2(e, 0.0), colR, c0, c1, c2.y);
    float ty = curtainThickness(g + float2(0.0, e), cc, c0, c1, c2.y);
    float2 grad = float2(tx - T, ty - T) / e;
    float rel = cc.front - g.y;
    float headLen = 9.0 + 14.0 * c1.y;
    float headness = exp(-sq(rel / (headLen * 2.2)));
    float fade = 1.0 - smoothstep(c2.x - 1.2, c2.x, c1.x);
    float side = smoothstep(0.0, 1.0, cc.xm);
    float headCover = smoothstep(0.02, 0.12, T) * fade * side;
    float4 headCol = shadeDrop(-grad * 4.5, T, headCover, 0.06, 1.0);
    headCol = underDark(headCol, min(1.0, highlightShadow(-grad * 4.5) * 1.3) * headCover * (0.42 + 0.4 * u.light.w));
    float2 nt = -grad * 3.5;
    nt *= min(1.0, 0.65 / max(length(nt), 1e-4));
    float4 trailCol = shadeWater(nt, float2(0.0, 1.0), T, smoothstep(0.02, 0.14, T) * fade * 0.7 * side, 40.0, 0.2, i.pos);
    float4 col = lerp(trailCol, headCol, headness);
    float2 nh = -grad * 4.5;
    float clear_ = smoothstep(0.06, 0.45, specGlow(nh, 24.0));
    float tintA = lerp(0.05, 0.12, headness) * smoothstep(0.02, 0.2, T) * fade * side * (1.0 - clear_);
    return underTint(col, float3(0.45, 0.53, 0.63), tintA);
}

// ---------- 마우스로 누른 물 ----------
// 무리마다 3개: p0 = (x, y, 반경, 알파), p1 = (늘어남 e·cos2φ, e·sin2φ, 잔 물방울 시작 번호, 개수),
// p2 = (그릴 반경, 합치는 거리 k, 그림자 진하기, 그림자 퍼짐). 잔 물방울은 (x, y, 반경, 0).

IdxOut pressVertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float4 p0 = items[iid * 3], p2 = items[iid * 3 + 2];
    float2 c = quadCorner(vid);
    IdxOut o;
    o.pos = toClip(p0.xy + (c * 2.0 - 1.0) * p2.x);
    o.idx = iid;
    return o;
}

float pressEllipseSD(float2 g, float4 p0, float4 p1) {
    float R = p0.z;
    if (R < 0.3) return 1e4;
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

float pressSmin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

float pressUnion(float2 g, float4 p0, float4 p1, float k) {
    float d = pressEllipseSD(g, p0, p1);
    int start = int(p1.z), n = int(p1.w);
    for (int j = 0; j < n; j++) {
        float4 m = items[start + j];
        d = pressSmin(d, length(g - m.xy) - m.z, k);
    }
    return d;
}

float4 pressFragment(IdxOut i) : SV_Target {
    float4 p0 = items[i.idx * 3], p1 = items[i.idx * 3 + 1], p2 = items[i.idx * 3 + 2];
    float2 g = worldOf(i.pos);
    float k = p2.y;
    float s = pressUnion(g, p0, p1, k);
    float px = 1.0 / u.timeInfo.y;
    float cover = 1.0 - smoothstep(-px * 0.7, px * 0.7, s);
    if (cover <= 0.001) discard;
    const float e = 0.5;
    float2 grad = float2(pressUnion(g + float2(e, 0.0), p0, p1, k) - pressUnion(g - float2(e, 0.0), p0, p1, k),
                         pressUnion(g + float2(0.0, e), p0, p1, k) - pressUnion(g - float2(0.0, e), p0, p1, k));
    float2 nO = grad / max(length(grad), 1e-5);
    float dm = pressEllipseSD(g, p0, p1);
    float wm = exp(-max(dm, 0.0) / 3.0);
    float wsum = wm, wacc = wm * clamp(p0.z * 0.2, 2.0, 8.0);
    int start = int(p1.z), n = int(p1.w);
    for (int j = 0; j < n; j++) {
        float4 m = items[start + j];
        float wt = exp(-max(length(g - m.xy) - m.z, 0.0) / 3.0);
        wsum += wt;
        wacc += wt * clamp(m.z * 0.9, 0.8, 8.0);
    }
    float w = wacc / max(wsum, 1e-5);
    cover *= lerp(1.0, p0.w, wm / max(wsum, 1e-5));
    float v = saturate(1.0 + s / w);
    float2 n2 = nO * v * 0.92;
    float4 col = shadeDrop(n2, 0.2, cover, 0.06, 1.0);
    col = underDark(col, min(1.0, highlightShadow(n2) * 1.3) * cover * (0.42 + 0.4 * u.light.w));
    float clear_ = smoothstep(0.06, 0.45, specGlow(n2, 24.0));
    col = underTint(col, float3(0.45, 0.53, 0.63), 0.07 * cover * (1.0 - clear_));
    return col;
}

float4 pressShadowFragment(IdxOut i) : SV_Target {
    float4 p0 = items[i.idx * 3], p1 = items[i.idx * 3 + 1], p2 = items[i.idx * 3 + 2];
    float2 g = worldOf(i.pos);
    float k = p2.y;
    const float2 offset = float2(0.0, 4.0);
    float2 q = g - offset;
    float dm = pressEllipseSD(q, p0, p1);
    float wt = exp(-max(dm, 0.0) / 6.0), wsum = wt, size = wt * p0.z;
    float wMain = wt;
    int start = int(p1.z), n = int(p1.w);
    for (int j = 0; j < n; j++) {
        float4 m = items[start + j];
        float w = exp(-max(length(q - m.xy) - m.z, 0.0) / 6.0);
        wsum += w;
        size += w * m.z;
    }
    size /= max(wsum, 1e-5);
    float blur = clamp(size * 0.52 * p2.w, 3.0, 21.0 * p2.w);
    float sd = pressUnion(q, p0, p1, k);
    float t = 1.0 - smoothstep(-blur * 0.5, blur * 1.5, sd);
    float a = t * t * lerp(0.35, 1.0, smoothstep(3.0, 20.0, size)) * p2.z;
    a *= lerp(1.0, p0.w, wMain / max(wsum, 1e-5));
    a *= smoothstep(-1.0, 2.5, pressUnion(g, p0, p1, k));
    if (a < 0.002) discard;
    return float4(0.0, 0.0, 0.0, a);
}

// ---------- 유리 물방울 (실험) ----------
// 물방울 뒤 화면을 읽어서 가장자리에서 굴절시킨다. 안쪽은 평평해서 거의 그대로 보이고, 둥근 가장자리(베벨)에서
// 바깥 화면을 끌어와 휘어 보인다. 밝기 범위를 조금 좁혀 민무늬 배경에서도 보이게 한다 (맥판 유리 필터의 face 값과 같은 방식).
// 빛은 큰 광택 대신 윤곽을 따라 가는 선으로 (빛 쪽이 밝고 반대쪽은 옅게)

float3 deskAt(float2 g) {
    return deskTex.SampleLevel(linearClamp, (g - u.screen.xy) / u.screen.zw, 0).rgb;
}

float4 pressGlassFragment(IdxOut i) : SV_Target {
    float4 p0 = items[i.idx * 3], p1 = items[i.idx * 3 + 1], p2 = items[i.idx * 3 + 2];
    float2 g = worldOf(i.pos);
    float k = p2.y;
    float s = pressUnion(g, p0, p1, k);
    float px = 1.0 / u.timeInfo.y;
    float cover = 1.0 - smoothstep(-px * 0.7, px * 0.7, s);
    if (cover <= 0.001) discard;
    const float e = 0.5;
    float2 grad = float2(pressUnion(g + float2(e, 0.0), p0, p1, k) - pressUnion(g - float2(e, 0.0), p0, p1, k),
                         pressUnion(g + float2(0.0, e), p0, p1, k) - pressUnion(g - float2(0.0, e), p0, p1, k));
    float2 nO = grad / max(length(grad), 1e-5);
    // 베벨 폭은 가까운 방울 크기를 따른다
    float dm = pressEllipseSD(g, p0, p1);
    float wm = exp(-max(dm, 0.0) / 3.0);
    float wsum = wm, wacc = wm * clamp(p0.z * 0.4, 2.0, 12.0);
    int start = int(p1.z), n = int(p1.w);
    for (int j = 0; j < n; j++) {
        float4 m = items[start + j];
        float wt = exp(-max(length(g - m.xy) - m.z, 0.0) / 3.0);
        wsum += wt;
        wacc += wt * clamp(m.z * 0.6, 0.8, 12.0);
    }
    float bevel = wacc / max(wsum, 1e-5);
    cover *= lerp(1.0, p0.w, wm / max(wsum, 1e-5));
    float t = saturate(-s / bevel);              // 0 = 윤곽, 1 = 평평한 안쪽
    float bend = (1.0 - t) * (1.0 - t);
    // 가장자리일수록 안쪽 화면을 끌어와 바깥으로 늘여 보인다 (맥 리퀴드 글래스처럼 밖으로 휘는 굴절).
    // 바깥 화면을 끌어오면 볼록렌즈처럼 안으로 모여 보였다. 색마다 조금씩 달리 휘어 가장자리에 옅은 색 번짐
    float2 off = -nO * bevel * bend * 1.2 * u.glass.x;
    float3 col = float3(deskAt(g + off * 1.04).r, deskAt(g + off).g, deskAt(g + off * 0.96).b);
    float blur = u.glass.y;
    if (blur > 0.05) {
        float3 acc = col;
        [unroll] for (int b = 0; b < 8; b++) {
            float a = b * 0.785398;
            acc += deskAt(g + off + float2(cos(a), sin(a)) * blur);
        }
        col = acc / 9.0;
    }
    // 밝기 범위를 좁힌다: 흰색은 조금 어둡게, 검은색은 조금 밝게
    float white = 1.0 - 0.2 * u.glass.z, black = 0.1 * u.glass.w;
    col = black + col * (white - black);
    // 윤곽을 따라 가는 빛 선: 빛이 오는 쪽이 밝고, 반대쪽은 옅게
    float2 ld = normalize(u.light.xy);
    float facing = dot(nO, ld);
    float line_ = exp(-sq((-s - 0.6) / 0.7));
    float rimLight = line_ * (0.06 + 0.32 * sq(saturate(facing)) + 0.1 * sq(saturate(-facing))) * u.light.z;
    col = col * (1.0 - 0.03 * bend) + rimLight * (1.0 - col * 0.6);
    return float4(saturate(col) * cover, cover);
}
