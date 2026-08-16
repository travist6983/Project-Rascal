/**
 * The capture control: terracotta disc that becomes a rounded square while live.
 */
export interface RecordButtonProps {
  recording?: boolean;
  onClick?: () => void;
  style?: React.CSSProperties;
}
export function RecordButton(props: RecordButtonProps): JSX.Element;
