#!/usr/bin/env python3
"""FlockOS's partition layout of a jetson-orin NVMe (WP-6.2), from the BSP's.

    tegra-layout.py BSP_LAYOUT OUT

BSP_LAYOUT is the BSP's tools/kernel_flash/flash_l4t_t234_nvme_rootfs_ab.xml,
NVIDIA's layout of an NVMe with rootfs A/B. It is under NVIDIA's licence, so
it is read from the BSP (build/fetch-bsp.sh) and never copied into this
repository. OUT gets the same layout plus FlockOS's `data` partition after
APP_b, grown to the end of the disk (/data, PARTLABEL=data in /etc/fstab).

Everything else stays NVIDIA's: the A/B kernel and device tree partitions,
recovery, `esp` (FlockOS's /boot/efi; flash.sh builds its image only under
that name), APP and APP_b with their placeholders (APPSIZE, APPFILE,
APPUUID...), which l4t_initrd_flash.sh fills in. The script refuses a layout
that is not shaped as FlockOS expects, so a BSP update that changes it fails
the build instead of flashing something else.
"""
import sys
import xml.etree.ElementTree as ET

ESP_TYPE = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
# Linux filesystem data (Discoverable Partitions Specification).
LINUX_DATA_TYPE = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
# Allocation attribute 0x808: as APP in NVIDIA's single-slot layout, the
# partition grows to the end of the device.
GROW = "0x808"
# The smallest data partition: it is resized to the disk anyway.
DATA_MIN_SIZE = 268435456


def fail(msg):
    sys.stderr.write(f"tegra-layout: {msg}\n")
    sys.exit(1)


def text(part, tag):
    node = part.find(tag)
    return (node.text or "").strip() if node is not None else ""


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: tegra-layout.py BSP_LAYOUT OUT\n")
        return 2
    src, out = argv[1], argv[2]
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    try:
        tree = ET.parse(src, parser=parser)
    except (OSError, ET.ParseError) as err:
        fail(f"cannot read {src}: {err}")
    root = tree.getroot()
    if root.tag != "partition_layout":
        fail(f"{src} is not a partition layout")
    devices = root.findall("device")
    if len(devices) != 1 or devices[0].get("type") != "external":
        fail("expected one external device (the NVMe layout of l4t_initrd_flash.sh)")
    device = devices[0]
    parts = device.findall("partition")
    names = [p.get("name") for p in parts]
    if len(set(names)) != len(names):
        fail("partition names are not unique")
    if "data" in names:
        fail("the BSP's layout already has a partition named data")
    for need in ("esp", "APP", "APP_b", "secondary_gpt"):
        if need not in names:
            fail(f"the BSP's layout has no {need} partition")
    if names[-1] != "secondary_gpt":
        fail("secondary_gpt is not the last partition")
    if names[-3:-1] != ["APP", "APP_b"]:
        fail(f"APP and APP_b are not the last partitions before secondary_gpt: {names[-3:-1]}")
    esp = parts[names.index("esp")]
    if text(esp, "partition_type_guid").upper() != ESP_TYPE:
        fail("esp is not an EFI system partition")
    for name in ("APP", "APP_b"):
        if text(parts[names.index(name)], "size") != "APPSIZE":
            fail(f"{name}'s size is not the APPSIZE placeholder")

    # The new partition, written like its neighbours.
    app_b = parts[names.index("APP_b")]
    data = ET.Element("partition", {"name": "data", "type": "data"})
    data.text = app_b.text
    fields = [
        ("allocation_policy", "sequential"),
        ("filesystem_type", "basic"),
        ("size", str(DATA_MIN_SIZE)),
        ("file_system_attribute", "0"),
        ("allocation_attribute", GROW),
        ("align_boundary", "16384"),
        ("percent_reserved", "0"),
        ("partition_type_guid", LINUX_DATA_TYPE),
        ("description", "FlockOS: /data, the device's state across A/B updates; grows to the end of the disk."),
    ]
    child_tail = app_b[0].tail if len(app_b) else "\n"
    for i, (tag, value) in enumerate(fields):
        node = ET.SubElement(data, tag)
        node.text = f" {value} "
        node.tail = child_tail if i < len(fields) - 1 else app_b[-1].tail
    data.tail = app_b.tail
    comment = ET.Comment(" FlockOS (build/tegra-layout.py): /data after the root slots ")
    comment.tail = app_b.tail
    index = list(device).index(parts[-1])
    device.insert(index, comment)
    device.insert(index + 1, data)

    # What precedes the root element (the XML declaration and NVIDIA's
    # licence header) is kept as it is; ElementTree drops it.
    with open(src, encoding="utf-8") as f:
        head = f.read()
    start = head.find("<partition_layout")
    if start < 0:
        fail(f"{src} has no <partition_layout> element")
    with open(out, "w", encoding="utf-8") as f:
        f.write(head[:start])
        f.write(ET.tostring(root, encoding="unicode"))
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
