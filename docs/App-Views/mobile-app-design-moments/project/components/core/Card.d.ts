/**
 * The surface primitive: hairline border on paper, or a borderless tint block.
 */
export interface CardProps {
  /** none = surface + hairline. A tint drops the border and the shadow — the wash is the edge. */
  tint?: 'none' | 'peach' | 'lavender' | 'sage';
  /** Selected: 1.5px terracotta border + peach fill. Never a check mark. */
  selected?: boolean;
  /** Raise to --rascal-shadow-lift. Use when this card is what a sheet is asking about. */
  lifted?: boolean;
  /** 20px web/timeline, 24px app prompt cards. */
  radius?: string;
  padding?: number | string;
  children?: React.ReactNode;
  onClick?: () => void;
  style?: React.CSSProperties;
}
export function Card(props: CardProps): JSX.Element;
