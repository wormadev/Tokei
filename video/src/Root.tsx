import { Composition } from "remotion";
import { Promo } from "./Promo";

// 6 scenes (19.5 s) minus 5 half-second fades.
export const RemotionRoot: React.FC = () => (
  <Composition id="Promo" component={Promo} durationInFrames={510} fps={30} width={1920} height={1080} />
);
