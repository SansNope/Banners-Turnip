# NewDriver RP-PAIR (Linux CI)

Workflow: **Actions → NewDriver wb RP-PAIR (Linux) → Run workflow**

| | |
|--|--|
| Mesa | `whitebelyash/mesa-unified` @ `7fdde2f8` |
| Patch | `patches/0010-renderpass-clean-wfm-pair.patch` |
| NDK / API / SDK | r29 / 34 / 36 |
| Output artifact | `Turnip-NewDriver-wb-26.2-RP-PAIR-LINUX` |

A/B against Windows zip `Turnip-NewDriver-wb-26.2-RENDERPASS-CLEAN-WFM-PAIR` (**Sysmem**).

## Import checklist (important)

GitHub “Download artifact” wraps files. Use the **inner** package or the flat zip from Actions that contains only:

- `libvulkan_freedreno.so`
- `meta.json`

| | Windows product | Real Linux build |
|--|--|--|
| SO size | **18885400** | **~15114416** (stripped) |
| fingerprint (example) | `b57a357c…` | **must differ** |
| git in SO | `7fdde2f8f8` | `7fdde2f8f8` (same pin) |

If log shows `size=18885400 fingerprint=b57a357c…` you are still on the **Windows** SO, not Linux.

Local:

```bash
SKIP_APT=1 ./build_newdriver_rp_pair.sh   # if deps already installed
# or just:
./build_newdriver_rp_pair.sh
```
