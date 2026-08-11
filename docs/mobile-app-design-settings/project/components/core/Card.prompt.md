Paper surface with a hairline, or a borderless tinted block.

```jsx
<Card>…timeline entry…</Card>
<Card tint="peach" radius="var(--rascal-radius-app-card)" padding={22}>…prompt…</Card>
```

Tinted cards carry **no border and no shadow** — that is deliberate, the wash is
the edge. Only untinted cards get the hairline. `lifted` is reserved for the one
card a bottom sheet refers to.
