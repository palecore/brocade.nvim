
# Brocade.nvim

A neovim plugin to aid development of Salesforce DX projects.

_This plugin is in a very early stage of development!_

## Configuration

`lazy.nvim` minimal plugin spec:

```lua
{
    "palecore/brocade.nvim",
    opts = {},
}
```

## Usage

* `:S` - a facade command to access core plugin functionalities
* `<leader>s` - a normal-mode keymap that begins the `:S` command line
* `:S target org` - get current project-default org
* `:S target org ORG-ALIAS` - set current project-default org
