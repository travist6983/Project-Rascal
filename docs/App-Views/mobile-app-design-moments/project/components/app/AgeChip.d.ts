/**
 * The periwinkle age stamp. The single most important piece of metadata in RASCAL.
 */
export interface AgeChipProps {
  /** '4 years, 2 months' or '4y 2m'. Long form on timeline, short form in headers. */
  children?: React.ReactNode;
  /** Usually 'Age'. */
  prefix?: string;
  style?: React.CSSProperties;
}
export function AgeChip(props: AgeChipProps): JSX.Element;
