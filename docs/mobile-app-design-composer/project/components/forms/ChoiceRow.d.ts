/**
 * A single-select answer row. RASCAL's only radio affordance — no dots, no ticks.
 * @startingPoint section="Forms" subtitle="Single-select answer rows" viewport="700x260"
 */
export interface ChoiceRowProps {
  selected?: boolean;
  children?: React.ReactNode;
  onClick?: () => void;
  style?: React.CSSProperties;
}
export function ChoiceRow(props: ChoiceRowProps): JSX.Element;
