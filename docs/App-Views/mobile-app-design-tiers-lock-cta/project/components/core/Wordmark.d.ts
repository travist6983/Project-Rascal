/**
 * The brand mark. RASCAL has no logo file — the letters ARE the mark.
 */
export interface WordmarkProps {
  /** Px. 19 in app chrome, 34+ for marketing hero. */
  size?: number;
  /** Canvas-colored, for use on ink. */
  inverted?: boolean;
  style?: React.CSSProperties;
}
export function Wordmark(props: WordmarkProps): JSX.Element;
