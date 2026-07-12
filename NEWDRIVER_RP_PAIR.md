# NewDriver RP-PAIR (Linux CI)

Workflow: **Actions → NewDriver wb RP-PAIR (Linux) → Run workflow**

| | |
|--|--|
| Mesa | `whitebelyash/mesa-unified` @ `7fdde2f8` |
| Patch | `patches/0010-renderpass-clean-wfm-pair.patch` |
| NDK / API / SDK | r29 / 34 / 36 |
| Output artifact | `Turnip-NewDriver-wb-26.2-RP-PAIR-LINUX` |

A/B against Windows zip `Turnip-NewDriver-wb-26.2-RENDERPASS-CLEAN-WFM-PAIR` (**Sysmem**).

Local:

```bash
SKIP_APT=1 ./build_newdriver_rp_pair.sh   # if deps already installed
# or just:
./build_newdriver_rp_pair.sh
```
