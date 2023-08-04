# systemd-boot-conversion

These scripts are a attempt to get Fedora to use systemd-boot on UEFI machines. There are two scripts, one with and one without secure boot support.

**Be warned** this is all "in development" code, I am not responsible for bricking/breaking your install!

## Here be dragons!
These scripts have been put together by my in various states of management. It's very possible some are broken or have breaking bugs. You have, again, been warned. 
The non-UKI scripts might cause system breakages, see the [issues](https://github.com/sebastiaanfranken/systemd-boot-conversion/issues).

## The future of this project
With [Fedora looking into making this a option](https://www.phoronix.com/news/Fedora-GRUB-Free-Proposal) for future releases (all that's missing are a few [key libraries](https://copr.fedorainfracloud.org/coprs/jlinton/sdubby/) that aren't in the main repos yet)
the question is: *does this code have any place in a modern Fedora install*?

For now that's a yes. As stated above, Fedora is only looking into it, and it's not yet clear cut. It may happen in Fedora 39, it may not.

Once/if this lands in the distro itself this project becomes pretty useless. Once/if that happens I'll update this README.
