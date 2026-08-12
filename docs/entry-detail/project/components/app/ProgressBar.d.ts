/**
 * 4px onboarding progress hairline. Only used during first-run.
 */
export interface ProgressBarProps {
  step?: number;
  total?: number;
  style?: React.CSSProperties;
}
export function ProgressBar(props: ProgressBarProps): JSX.Element;
