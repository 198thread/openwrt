// SPDX-License-Identifier: GPL-2.0
/*
 * MTD partition parser for ZyXEL/EcoNet tclinux TRX firmware images.
 *
 * The tclinux TRX format uses a big-endian header with magic "2RDH" (0x32524448).
 * The header contains separate kernel_len and rootfs_len fields; the rootfs
 * (squashfs) is padded to a 4MB boundary after the kernel.
 *
 * DTS usage:
 *   partition@1b80000 {
 *       label = "tclinux";
 *       reg = <0x01b80000 0x02800000>;
 *       compatible = "tclinux,trx";
 *   };
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/types.h>
#include <linux/byteorder/generic.h>
#include <linux/mtd/mtd.h>
#include <linux/mtd/partitions.h>
#include <linux/slab.h>

#include "mtdsplit.h"

/* Magic "2RDH" as stored in big-endian flash */
#define TCLINUX_TRX_MAGIC	0x32524448U

/* Minimum header size: magic(4) + hdrlen(4) + total_len(4) + crc32(4)
 * + version(32) + customer_version(32) + kernel_len(4) + rootfs_len(4)
 * = 88 bytes; actual header is 256 or 372 bytes.
 */
#define TCLINUX_HDR_MIN		88

/* Rootfs is padded to this alignment within the TRX image */
#define TCLINUX_ROOTFS_ALIGN	SZ_4M

struct tclinux_hdr {
	__be32 magic;
	__be32 hdrlen;
	__be32 total_len;
	__be32 crc32;
	u8     version[32];
	u8     customer_version[32];
	__be32 kernel_len;
	__be32 rootfs_len;
	/* more fields follow but we don't need them */
} __packed;

static int mtdsplit_parse_tclinux(struct mtd_info *master,
				  const struct mtd_partition **pparts,
				  struct mtd_part_parser_data *data)
{
	struct tclinux_hdr hdr;
	struct mtd_partition *parts;
	size_t retlen;
	size_t hdrlen, kernel_len, rootfs_offset, rootfs_size;
	int ret;

	/* Read header from start of partition */
	ret = mtd_read(master, 0, sizeof(hdr), &retlen, (u8 *)&hdr);
	if (ret || retlen != sizeof(hdr)) {
		pr_debug("short read from \"%s\"\n", master->name);
		return ret ? ret : -EIO;
	}

	if (be32_to_cpu(hdr.magic) != TCLINUX_TRX_MAGIC) {
		pr_debug("no tclinux TRX header in \"%s\" (magic=0x%08x)\n",
			 master->name, be32_to_cpu(hdr.magic));
		return -ENOENT;
	}

	hdrlen = be32_to_cpu(hdr.hdrlen);
	kernel_len = be32_to_cpu(hdr.kernel_len);

	if (hdrlen < TCLINUX_HDR_MIN || hdrlen > SZ_1M) {
		pr_warn("invalid hdrlen %zu in \"%s\"\n", hdrlen, master->name);
		return -EINVAL;
	}

	if (kernel_len == 0 || kernel_len > master->size) {
		pr_warn("invalid kernel_len 0x%zx in \"%s\"\n",
			kernel_len, master->name);
		return -EINVAL;
	}

	/* Rootfs starts after header+kernel, rounded up to TCLINUX_ROOTFS_ALIGN */
	rootfs_offset = ALIGN(hdrlen + kernel_len, TCLINUX_ROOTFS_ALIGN);
	if (rootfs_offset >= master->size) {
		pr_warn("rootfs offset 0x%zx exceeds partition size in \"%s\"\n",
			rootfs_offset, master->name);
		return -ENOENT;
	}

	rootfs_size = master->size - rootfs_offset;
	if (rootfs_size == 0) {
		pr_warn("zero rootfs size in \"%s\"\n", master->name);
		return -ENOENT;
	}

	parts = kcalloc(2, sizeof(*parts), GFP_KERNEL);
	if (!parts)
		return -ENOMEM;

	parts[0].name = KERNEL_PART_NAME;
	parts[0].offset = 0;
	parts[0].size = rootfs_offset;

	parts[1].name = ROOTFS_PART_NAME;
	parts[1].offset = rootfs_offset;
	parts[1].size = rootfs_size;

	pr_info("found tclinux TRX in \"%s\": kernel=0x%zx rootfs@0x%zx+0x%zx\n",
		master->name, kernel_len, rootfs_offset, rootfs_size);

	*pparts = parts;
	return 2;
}

static struct mtd_part_parser tclinux_trx_parser = {
	.owner		= THIS_MODULE,
	.name		= "tclinux-trx",
	.parse_fn	= mtdsplit_parse_tclinux,
	.type		= MTD_PARSER_TYPE_FIRMWARE,
};

static int __init mtdsplit_tclinux_init(void)
{
	register_mtd_parser(&tclinux_trx_parser);
	return 0;
}

module_init(mtdsplit_tclinux_init);
