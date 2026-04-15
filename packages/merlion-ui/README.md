# merlion-ui

Beautiful, copy-pasteable UI components for merlionjs. Like shadcn/ui, but for Zig.

## Philosophy

- **Copy, don't import** — Components are yours to modify. Copy them into your project.
- **Server-first** — Components render to HTML on the server, no hydration needed.
- **Zig-native** — Built with merlionjs's comptime HTML builder.

## Installation

```bash
# Add merlion-ui to your project
mer add ui

# Or add specific components
mer add ui button
mer add ui card
mer add ui dialog
```

## Available Components

| Component | Command | Description |
|-----------|---------|-------------|
| Button | `mer add ui button` | Clickable button with variants |
| Card | `mer add ui card` | Container with header, content, footer |
| Dialog | `mer add ui dialog` | Modal dialog with overlay |
| Input | `mer add ui input` | Text input with styling |
| Badge | `mer add ui badge` | Status indicators |
| Alert | `mer add ui alert` | Alert messages |
| Table | `mer add ui table` | Data tables |
| Tabs | `mer add ui tabs` | Tabbed interface |
| Accordion | `mer add ui accordion` | Collapsible sections |
| Select | `mer add ui select` | Dropdown select |

## Usage

Components are copied to `app/components/`:

```zig
const h = mer.h;
const Button = @import("components/button.zig");

pub fn render(req: mer.Request) mer.Response {
    return mer.html(Button.primary(.{
        .label = "Click me",
        .on_click = "handleClick()",
    }));
}
```

## Styling

Components use Tailwind CSS classes. Make sure you've added CSS:

```bash
mer add css
```

## Customization

After copying, edit the component directly. It's your code now.

## Creating Components

See `docs/creating-components.md` for guidelines on creating new merlion-ui components.

## License

MIT — same as merlionjs
