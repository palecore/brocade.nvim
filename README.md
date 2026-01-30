
# Brocade.nvim

A neovim plugin to aid development of Salesforce DX projects.

_This plugin is in a very early stage of development! Use at your own risk!_

## Requirements

* `curl` - used to make Salesforce REST API calls
* `sf` CLI utility & its project/user config files/dirs - used to obtain access
  token to the Orgs

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
* `<leader>s` - a normal-mode keymap that begins the `:S<space>` command line
* `:S target org` - get current project-default org
* `:S target org ORG-ALIAS` - set current project-default org
* `:S apex run this [--target-org TARGET-ORG]` - run the current buffer as
  anonymous Apex
    * full debug log as well as filtered "user debug" logs will be retrieved
    * potential compilation or runtime errors will be shown as file diagnostics
    * the `SFDC_CONSOLE` trace flag record of the running user will be updated
      to be valid at the current moment and to expire in several minutes - this
      is needed to record the logs
