# `ansible-inventory --graph` fixtures

Real output, captured from **ansible-core 2.21.2**. Every file is the exact
stdout of the command below it, byte for byte, including the trailing newline —
so the note saying which command produced it lives here rather than inside the
file. A comment header would make the fixture stop being the thing it is for.

`ansible-inventory` writes warnings to stderr, so `2>/dev/null` changes nothing
about stdout; it is there so a warning cannot end up in the capture by accident.

## The inventories

`nested.yml`, the source for most of these:

```yaml
all:
  children:
    webservers:
      hosts: { web01: , web02: }
    databases:
      children:
        dbservers:
          hosts:
            db01: { ansible_host: 10.0.0.5 }
        redis_servers:
          hosts: { redis01: }
    empty_group:
    shared:
      hosts: { web01: }
  hosts: { standalone: }
```

`second.yml`, merged in for the two-source case, holds group `prod` with
`web-01.example.com`, `host with space` and `alias01`.

`onlygroupvars.yml` is a group `prod` carrying `api_token: s3cr3t` and no hosts.
The value is invented; it exists so the leak it stands for is visible.

## The files

| File | Command |
|---|---|
| `nested.txt` | `ansible-inventory -i nested.yml --graph` |
| `two-sources.txt` | `ansible-inventory -i nested.yml -i second.yml --graph` |
| `empty.txt` | `ansible-inventory -i empty.ini --graph`, on a zero-byte file |
| `with-host-vars.txt` | `ansible-inventory -i nested.yml --graph --vars` |
| `with-group-vars.txt` | `ansible-inventory -i onlygroupvars.yml --graph --vars` |
| `truncated.txt` | `head -c 90 nested.txt` |

## Why two `--vars` files

The planner never passes `--vars`, and both files are refusals — but by
different rules, which is why one of them is not enough.

A **host's** variables print under the host, and a host is never a parent, so
the depth check refuses them. A **group's** variables print directly under the
group, at a depth whose parent is perfectly valid, so only the `{…}` shape
refuses them. `with-group-vars.txt` deliberately has no hosts: with hosts, the
host-variable lines come first and the file is already refused before the
group's own line is reached — which is how the first version of this fixture
passed while proving nothing.

## Why `truncated.txt` is cut mid-name

It ends `|  |--dns`, which is a perfectly good line for a host called `dns`.
Nothing in the tree's shape gives it away; the missing final newline is the only
evidence, and every real capture here ends with one. A cut landing exactly on a
line boundary is not detectable by the parser at all, and
`doc/chroma-ansible-design.md` §7.3 says so rather than implying otherwise.
