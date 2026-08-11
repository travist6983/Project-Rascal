/**
 * The small uppercase structural label above a section or card.
 */
export interface EyebrowLabelProps {
  children?: React.ReactNode;
  tone?: 'muted' | 'accent';
  style?: React.CSSProperties;
}
export function EyebrowLabel(props: EyebrowLabelProps): JSX.Element;
