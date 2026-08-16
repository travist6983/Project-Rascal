Single-select row. Selection is shown by fill + border weight, never a control.

```jsx
<ChoiceRow selected={v === 'voice'} onClick={() => set('voice')}>I want to remember his voice</ChoiceRow>
```

Rows carry the answer in the user's own words ("He's growing up too fast"), set in
Nunito 700 — they read as sentences the user is choosing, not options in a form.
Stack them in a flex column with `gap: 12px`.
