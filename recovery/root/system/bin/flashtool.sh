#!/sbin/sh

export OUTFD=$4;
package=$1


show_progress() { echo "progress $1 $2" >> /proc/self/fd/$OUTFD; }
ui_print() { until [ -z "$1" ]; do echo "ui_print $1\nui_print" >> /proc/self/fd/$OUTFD; shift; done; }
abort() { ui_print "$@"; exit 1; }


grep_cmdline() {
  local REGEX="s/^$1=//p"
  { echo $(cat /proc/cmdline) | xargs -n 1; sed -e 's/ = /=/g' /proc/bootconfig; } 2>/dev/null | sed -n "$REGEX"
}
get_slot() {
  local SLOT=$(grep_cmdline androidboot.slot_suffix)
  [ -z "$SLOT" ] && SLOT=$(grep_cmdline androidboot.slot) && [ -n "$SLOT" ] && SLOT=_${SLOT}
  [ "$SLOT" != "normal" ] && echo "$SLOT"
}


slot=$(get_slot)
slot=$(echo "$slot" | tr -d '"' | tr -d ' ') 
if [ "$slot" = "_a" ]; then
    target_slot="_b"
    target_index=1
else 
    target_slot="_a"
    target_index=0
fi


## 一加13T
#supersize=14956888064
#groupsize=14952693760

metadatasize=65536

supersize=$(blockdev --getsize64 /dev/block/by-name/super)
groupsize=$(echo "$supersize - 4194304" | bc)

super_group=qti_dynamic_paritions
tmpdir=/data/tmp
qti_group=${super_group}${target_slot}


mksuper(){
  Imgdir=$1
  outputimg=$2
  
  super="--metadata-size $metadatasize --super-name super --virtual-ab --block-size 4096 "
  super+="--device-size $supersize --metadata-slots 3 "
  super+="--group ${qti_group}:$groupsize --group ${super_group}${slot}:$groupsize " 
  
  for imag in $(basename -a "$Imgdir"/*.img);do
    image=${imag%.img} 
    img_path="$Imgdir/$image.img"
    [ ! -s "$img_path" ] && continue 
    
    img_size=$(wc -c < "$img_path")
    super+="--partition ${image}${target_slot}:readonly:${img_size}:${qti_group} --image ${image}${target_slot}=${img_path} "
    super+="--partition ${image}${slot}:readonly:0:${super_group}${slot} "
  done  
  
  super+="--force-full-image --output $outputimg"
  if ! lpmake $super 2>/tmp/lpmake_err.log; then
    abort "--lpmake失败：$(cat /tmp/lpmake_err.log)"
  fi
  ui_print "--super.img 合成成功"
}

flashImg(){
  Imgdir=$1 
  target_imgs="abl.img aop.img aop_config.img bluetooth.img boot.img cpucp.img cpucp_dtb.img devcfg.img dsp.img dtbo.img engineering_cdt.img featenabler.img hyp.img imagefv.img init_boot.img keymaster.img modem.img oplus_sec.img oplusstanvbk.img pdp.img pdp_cdb.img pvmfw.img qupfw.img shrm.img soccp_dcd.img soccp_debug.img splash.img spuservice.img tz.img uefi.img uefisecapp.img vbmeta.img vbmeta_system.img vbmeta_vendor.img vendor_boot.img xbl.img xbl_config.img xbl_ramdump.img"
  
  for img_name in $target_imgs; do
    img_path="$Imgdir/$img_name"
    part_name=${img_name%.img}
    [ ! -s "$img_path" ] && { ui_print "--跳过不存在的 $img_name"; continue; }
    
    target_part="${part_name}${target_slot}"
    ui_print "--刷入 $target_part"
    dd if="$img_path" of="/dev/block/by-name/${target_part}" bs=4M || abort "--刷入 $target_part 失败"
    ui_print "----$part_name 完成----"
  done
}


ui_print "          FlashTool         "
ui_print "--当前槽位: $slot  刷入槽位: $target_slot"
show_progress 0.1 10;

rm -rf $tmpdir && mkdir -p $tmpdir
ui_print "--提取OTA包..."
startTime_s=$(date +%s)
payload_extract -i "$package" -x -o "$tmpdir/payload" -T4
ui_print "--解包用时: $(( $(date +%s) - startTime_s )) 秒"



if [ -b "/dev/block/mapper/my_company${slot}" ]; then
    ui_print "从当前系统复制my_company,my_preload"
    dd if="/dev/block/mapper/my_company${slot}" of="$tmpdir/payload/my_company.img" bs=4M
    dd if="/dev/block/mapper/my_preload${slot}" of="$tmpdir/payload/my_preload.img" bs=4M
else
    ui_print "使用氧系统的my_company,my_preload"
    cp -f "/system/bin/my_company.img" "/system/bin/my_preload.img" "$tmpdir/payload/"
fi



ui_print "--合成super.img..."
startTime_s=$(date +%s)
mkdir -p $tmpdir/super
for img in my_bigball.img my_carrier.img my_company.img my_engineering.img my_heytap.img my_manifest.img my_preload.img my_product.img my_region.img my_stock.img odm.img product.img system.img system_dlkm.img system_ext.img vendor.img vendor_dlkm.img; do
  [ -f "$tmpdir/payload/$img" ] && mv -f "$tmpdir/payload/$img" "$tmpdir/super"
done
mksuper $tmpdir/super $tmpdir/super.img  
ui_print "--合成用时: $(( $(date +%s) - startTime_s )) 秒"
[ ! -s "$tmpdir/super.img" ] && abort "super.img 合成失败"

ui_print "--刷入镜像..."
startTime_s=$(date +%s)
flashImg $tmpdir/payload
ui_print "--刷入用时: $(( $(date +%s) - startTime_s )) 秒"

ui_print "--刷入super.img..."
cat "$tmpdir/super.img" > "/dev/block/by-name/super"  || abort "super.img 刷入失败"

ui_print "--切槽至 $target_slot"
bootctl set-active-boot-slot $target_index || ui_print "！！切槽失败，请手动执行 fastboot set_active ${target_slot/_/}"
avbctl disable-verity --force && avbctl disable-verification --force
rm -rf /tmp $tmpdir
ui_print "---安装完成，挂载失败提示可忽略---"
show_progress 0.1 10;

