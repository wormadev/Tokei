import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { useVideoConfig } from "remotion";
import { DetailsScene, IntroScene, MenuBarScene, OutroScene, PanelScene, SettingsScene } from "./scenes";

export const Promo = () => {
  const { fps } = useVideoConfig();
  const t = <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: Math.round(0.5 * fps) })} />;
  return (
    <TransitionSeries>
      <TransitionSeries.Sequence name="Intro" durationInFrames={2.5 * fps} premountFor={fps}>
        <IntroScene />
      </TransitionSeries.Sequence>
      {t}
      <TransitionSeries.Sequence name="Menu bar" durationInFrames={3.5 * fps} premountFor={fps}>
        <MenuBarScene />
      </TransitionSeries.Sequence>
      {t}
      <TransitionSeries.Sequence name="Panel" durationInFrames={3.5 * fps} premountFor={fps}>
        <PanelScene />
      </TransitionSeries.Sequence>
      {t}
      <TransitionSeries.Sequence name="Details" durationInFrames={3.5 * fps} premountFor={fps}>
        <DetailsScene />
      </TransitionSeries.Sequence>
      {t}
      <TransitionSeries.Sequence name="Settings" durationInFrames={3.5 * fps} premountFor={fps}>
        <SettingsScene />
      </TransitionSeries.Sequence>
      {t}
      <TransitionSeries.Sequence name="Outro" durationInFrames={3 * fps} premountFor={fps}>
        <OutroScene />
      </TransitionSeries.Sequence>
    </TransitionSeries>
  );
};
