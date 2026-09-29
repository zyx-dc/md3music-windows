#include <flutter/runtime_effect.glsl>

// 逐像素深度位移封面（接口与 lib/widgets/depth_shader_cover.dart 对齐）
// 采样器 0: 原封面  1: 灰度深度图  2: 修补背景
// float uniform: 0..1 uSize, 2..3 uTilt, 4 uShift, 5 uHoleLo, 6 uHoleHi

uniform sampler2D uCover;
uniform sampler2D uDepth;
uniform sampler2D uBgFill;

uniform vec2 uSize;
uniform vec2 uTilt;
uniform float uShift;
uniform float uHoleLo;
uniform float uHoleHi;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  float depth = texture(uDepth, uv).r;

  // 近处（depth 大）位移更大；depth = 0.5 为不动层
  vec2 offset = uTilt * uShift * (depth - 0.5);
  vec2 srcUv = clamp(uv + offset, vec2(0.0), vec2(1.0));

  vec4 base = texture(uCover, srcUv);

  // 让出区：本像素原属近处物体（depth 大），但采样到的可见表面更远
  float srcDepth = texture(uDepth, srcUv).r;
  float hole = smoothstep(uHoleLo, uHoleHi, depth - srcDepth);
  vec4 bg = texture(uBgFill, srcUv);

  fragColor = mix(base, bg, hole);
}
