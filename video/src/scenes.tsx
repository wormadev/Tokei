import { Easing, Img, interpolate, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { ACCENT, Caption, Rise, Split, Stage } from "./ui";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

export const IntroScene = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  return (
    <Stage>
      <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center" }}>
        <Img
          src={staticFile("icon-dark.png")}
          style={{
            width: 300,
            height: 300,
            scale: interpolate(frame, [0, 1 * fps], [0.6, 1], { ...clamp, easing: Easing.spring({ damping: 14 }), output: "perceptual-scale" }),
            opacity: interpolate(frame, [0, 0.4 * fps], [0, 1], clamp),
          }}
        />
        <Rise delay={0.5} style={{ textAlign: "center", marginTop: 24 }}>
          <div style={{ fontSize: 110, fontWeight: 800, letterSpacing: -3 }}>Tokei</div>
          <div style={{ fontSize: 40, color: "rgba(255,255,255,0.6)", marginTop: 8 }}>
            Your Claude and Codex plan limits, in the menu bar.
          </div>
        </Rise>
      </div>
    </Stage>
  );
};

export const MenuBarScene = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const move = { ...clamp, easing: Easing.bezier(0.65, 0, 0.35, 1) };
  return (
    <Stage>
      <div style={{ position: "absolute", top: 0, left: 0, right: 0, height: 90, backgroundColor: "#08121A", borderBottom: "1px solid rgba(255,255,255,0.08)" }} />
      <div
        style={{
          position: "absolute",
          top: 0,
          right: 380,
          height: 90,
          borderRadius: interpolate(frame, [0.6 * fps, 1.4 * fps], [0, 12], move),
          overflow: "hidden",
          outline: `1px solid rgba(255,255,255,${interpolate(frame, [0.6 * fps, 1.4 * fps], [0, 0.14], move)})`,
          boxShadow: `0 20px 60px rgba(0,0,0,${interpolate(frame, [0.6 * fps, 1.4 * fps], [0, 0.6], move)})`,
          transformOrigin: "top right",
          scale: interpolate(frame, [0.6 * fps, 1.4 * fps], [1, 3], move),
          translate: interpolate(frame, [0.6 * fps, 1.4 * fps], ["0px 0px", "-420px 160px"], move),
        }}
      >
        <Img src={staticFile("tokei-menubar.png")} style={{ height: 90, display: "block" }} />
      </div>
      <div style={{ position: "absolute", left: 140, bottom: 160 }}>
        <Caption delay={1.3} title="Always in view." sub="Session on top, weekly below. Rings fill as you use your plan." />
      </div>
    </Stage>
  );
};

export const PanelScene = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  return (
    <Stage>
      <Split caption={<Caption title="Click for the details." sub="How much is left, when it resets, and whether your pace lasts until then." />}>
        <Img
          src={staticFile("panel.png")}
          style={{
            width: 900,
            translate: interpolate(frame, [0, 0.8 * fps], ["0px -80px", "0px 0px"], { ...clamp, easing: Easing.bezier(0.16, 1, 0.3, 1) }),
            opacity: interpolate(frame, [0, 0.5 * fps], [0, 1], clamp),
          }}
        />
      </Split>
    </Stage>
  );
};

export const DetailsScene = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  return (
    <Stage>
      <Split caption={<Caption title="Details on demand." sub="7-day history, per-model limits, service outages. All opt-in." />}>
        <Img
          src={staticFile("panel-full.png")}
          style={{
            height: 900,
            scale: interpolate(frame, [0, 3.5 * fps], [1, 1.04], clamp),
            opacity: interpolate(frame, [0, 0.5 * fps], [0, 1], clamp),
          }}
        />
      </Split>
    </Stage>
  );
};

export const SettingsScene = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const swap = interpolate(frame, [1.8 * fps, 2.3 * fps], [0, 1], clamp);
  const img = { position: "absolute", width: 1000, left: "50%", top: "50%", translate: "-50% -50%" } as const;
  return (
    <Stage>
      <Split caption={<Caption title="Quiet by design." sub="Refreshes faster while an agent is working. No Keychain prompts in the background." />}>
        <div style={{ position: "relative", width: 1000, height: 720 }}>
          <Img src={staticFile("settings-general.png")} style={{ ...img, opacity: 1 - swap }} />
          <Img src={staticFile("settings-display.png")} style={{ ...img, opacity: swap }} />
        </div>
      </Split>
    </Stage>
  );
};

export const OutroScene = () => (
  <Stage>
    <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 48 }}>
      <Rise>
        <Img src={staticFile("icon-dark.png")} style={{ width: 200, height: 200 }} />
      </Rise>
      <Rise delay={0.3}>
        <div style={{ fontFamily: "SF Mono, Menlo, monospace", fontSize: 46, padding: "28px 48px", borderRadius: 20, border: "2px solid rgba(255,255,255,0.14)", backgroundColor: "#16191D" }}>
          <span style={{ color: ACCENT }}>brew</span> install --cask wormadev/tap/tokei
        </div>
      </Rise>
      <Rise delay={0.6}>
        <div style={{ fontSize: 36, color: "rgba(255,255,255,0.6)" }}>github.com/wormadev/Tokei · macOS 26+</div>
      </Rise>
    </div>
  </Stage>
);
