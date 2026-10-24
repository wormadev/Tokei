import type React from "react";
import { Easing, interpolate, useCurrentFrame, useVideoConfig } from "remotion";

export const BG = "#0E1013";
export const ACCENT = "#32ADE6";
export const FONT = '"SF Pro Display", -apple-system, "Helvetica Neue", sans-serif';

export const Stage: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div style={{ position: "absolute", inset: 0, backgroundColor: BG, fontFamily: FONT, color: "white" }}>
    {children}
  </div>
);

/** Fades and lifts its children in, starting `delay` seconds into the scene. */
export const Rise: React.FC<{ delay?: number; style?: React.CSSProperties; children: React.ReactNode }> = ({
  delay = 0,
  style,
  children,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const range = [delay * fps, (delay + 0.7) * fps];
  const opts = { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: Easing.bezier(0.16, 1, 0.3, 1) } as const;
  return (
    <div style={{ opacity: interpolate(frame, range, [0, 1], opts), translate: interpolate(frame, range, ["0px 40px", "0px 0px"], opts), ...style }}>
      {children}
    </div>
  );
};

export const Caption: React.FC<{ title: string; sub?: string; delay?: number }> = ({ title, sub, delay = 0.2 }) => (
  <Rise delay={delay} style={{ maxWidth: 640 }}>
    <div style={{ fontSize: 64, fontWeight: 700, lineHeight: 1.1, letterSpacing: -1 }}>{title}</div>
    {sub ? <div style={{ fontSize: 34, color: "rgba(255,255,255,0.6)", marginTop: 24, lineHeight: 1.35 }}>{sub}</div> : null}
  </Rise>
);

/** Caption on the left, a screenshot on the right. */
export const Split: React.FC<{ children: React.ReactNode; caption: React.ReactNode }> = ({ children, caption }) => (
  <div style={{ position: "absolute", inset: 0, display: "flex", alignItems: "center", padding: "0 140px", gap: 100 }}>
    <div style={{ flex: "0 0 640px" }}>{caption}</div>
    <div style={{ flex: 1, display: "flex", justifyContent: "center", alignItems: "center" }}>{children}</div>
  </div>
);
