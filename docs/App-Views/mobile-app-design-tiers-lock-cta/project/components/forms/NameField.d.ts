/**
 * Display-size text entry with a blinking caret on a terracotta underline.
 */
export interface NameFieldProps {
  value?: string;
  placeholder?: string;
  caret?: boolean;
  /** Px. 38 for a name, smaller for secondary entry. */
  size?: number;
  style?: React.CSSProperties;
}
export function NameField(props: NameFieldProps): JSX.Element;
