/**
 * The recording meter: rounded bars that wave while live and rest flat when idle.
 */
export interface WaveformMeterProps {
  active?: boolean;
  bars?: number;
  height?: number;
  style?: React.CSSProperties;
}
export function WaveformMeter(props: WaveformMeterProps): JSX.Element;
