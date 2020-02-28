#!/bin/bash

# hdd-spindown.sh
# ---------------
# Automatic Disk Standby Using Kernel Diskstats and hdparm
# (C) 2011-2017 Alexander Koch <mail@alexanderkoch.net>
#
# Released under the terms of the MIT License, see 'LICENSE'


# default configuration file
# readonly用来定义只读变量，一旦使用readonly定义的变量在脚本中就不能更改
readonly CONFIG="${CONFIG:-/etc/hdd-spindown.rc}"

# check prerequisites   检查先决条件
function check_req() {
	FAIL=0
	#$@ 以一个单字符串显示所有向脚本传递的参数。 如"$@"用「"」括起来的情况、以"$1" "$2" … "$n" 的形式输出所有参数。
	for CMD in $@; do
	    #如果有返回，说明报错
		which $CMD &>/dev/null && continue 
		#>&2 也就是把结果输出到和标准错误一样；之前如果有定义标准错误重定向到某file文件，那么标准输出也重定向到这个file文件。
        # 其中&的意思，可以看成是“The same as”、“与...一样”的意思
		echo "error: missing '$CMD' executable in PATH" >&2
		FAIL=1
	done
	[ $FAIL -ne 0 ] && exit 1  //如果FAIL 不是 0 退出进程  退出状态为1 意思是 文件不存在 或未知错误
}


#logger是一个shell命令接口，可以通过该接口使用Syslog的系统日志模块，还可以从命令行直接向系统日志文件写入一行信息。	
function log() {
	if [ $CONF_SYSLOG -eq 1 ]; then
		logger -t "hdd-spindown.sh" --id=$$ "$1"
	else
		echo "$1"
	fi
}


function selftest_active() {
    # -q 存在  Self-test routine in progress 正在进行自检程序
	smartctl -a "/dev/$1" | grep -q "Self-test routine in progress"
	return $?
}

# 设备状态
function dev_stats() {
	read R_IO R_M R_S R_T W_IO REST < "/sys/block/$1/stat"
	echo "$R_IO $W_IO"
}

function dev_isup() {
    # grep -q 如果有匹配的内容则立即返回状态值0（true）。
	smartctl -i -n standby "/dev/$1" | grep -q ACTIVE
	return $?
}

function dev_spindown() {
	# skip spindown if already spun down  如果已经停转，则跳过停转
	# 如果这个命令执行失败了 || 那么就执行这个命令
	dev_isup "$1" || return 0

	# omit spindown if SMART Self-Test in progress  如果正在进行SMART自检，则忽略停转
	selftest_active "$1" && return 0

    
	# spindown disk   停转磁盘
	# suspending 正在暂停
	log "suspending $1"

	# hdparm -q 在执行后续的参数时，不在屏幕上显示任何信息。  hdparm -y 使硬盘停转
	hdparm -qy "/dev/$1"
	
	# -eq     //equal  等于
    # -ne     //no equal 不等于
    # -gt      //great than 大于
    # -lt       // low than  小于
    # -ge      // great and equal 大于等于
    # -le      //low and equal 小于等于

	if [ $? -gt 0 ]; then
	    #  suspend 暂停
		log "failed to suspend $1"
		return 1
	fi

	return 0
}

# spinup 起转
function dev_spinup() {
	# skip spinup if already online  如果已经在线，则跳过起转
	#如果这个命令执行成功 && 那么执行这个命令
	dev_isup "$1" && return 0

	# read raw blocks, bypassing cache   读原始块 绕过缓存
	log "spinning up $1"
	# dd：用指定大小的块拷贝一个文件，并在拷贝的同时进行指定的转换。
	# if=文件名：输入文件名
	# of=文件名：输出文件名
	# bs=bytes：同时设置读入/输出的块大小为bytes个字节。
	# count=blocks：仅拷贝blocks个块，块大小等于ibs指定的字节数。
	# ibs=bytes：一次读入bytes个字节，即指定一个块大小为bytes个字节。
	# iflag=direct 对数据使用直接I / O，避免使用缓冲区高速缓存。
	dd if=/dev/$1 of=/dev/null bs=1M count=$CONF_READLEN iflag=direct &>/dev/null
}

# 更新在线状态
function update_presence() {
	# no action if no hosts defined  如果未定义主机，则不执行任何操作
	[ -z "$CONF_HOSTS" ] && return 0

	# assume present if any host is ping'able  如果有主机可ping通，则假定存在
	for H in "${CONF_HOSTS[@]}"; do
		if ping -c 1 -q "$H" &>/dev/null; then
			if [ $USER_PRESENT -eq 0 ]; then
				log "active host detected ($H)"
				USER_PRESENT=1
			fi
			return 0
		fi
	done

	# absent 缺席
	if [ $USER_PRESENT -eq 1 ]; then
	    # 所有主机不活动
		log "all hosts inactive"
		USER_PRESENT=0
	fi

	return 0
}

function check_dev() {
	# initialize real device name   初始化真实设备名称
	DEV="${DEVICES[$1]}"
	# -e 文件是否存在
	if ! [ -e "/dev/$DEV" ]; then
	    # -L 符号链接 (link) 是否存在
		if [ -L "/dev/disk/by-id/$DEV" ]; then
		    # readlink是linux用来找出符号链接所指向的位置
			# basename 是去除目录后剩下的名字
			DEV="$(basename "$(readlink "/dev/disk/by-id/$DEV")")"
			# recognized 识别出
			log "recognized disk: ${DEVICES[$1]} --> $DEV"
			DEVICES[$1]="$DEV"
		else
		    # 跳过丢失的设备
			log "skipping missing device '$DEV'" >&2
			return 0
		fi
	fi
	
	# initialize r/w timestamp  初始化读写时间戳
	# -z 是否为零
	# 如果这个命令执行成功 && 那么执行这个命令
	# %s 总秒数。起算时间为1970-01-01 00:00:00 UTC。 	
	[ -z "${STAMP[$1]}" ] && STAMP[$1]=$(date +%s)

	# check for user presence, spin up if required  检查用户状态，需要时启动
	# -eq 等于
	if [ $USER_PRESENT -eq 1 ]; then
	    #如果这个命令执行失败了 || 那么就执行这个命令
		#dev_isup 是否旋转 
		# 如果旋转是假的 那么就执行起转
		dev_isup "$DEV" || dev_spinup "$DEV"
	fi

	# refresh r/w stats 更新读写状态
	COUNT_NEW="$(dev_stats "$DEV")"

	# spindown logic if stats equal previous recordings 如果统计数据等于先前的记录，则产生停转逻辑
	if [ "${COUNT[$1]}" == "$COUNT_NEW" ]; then
		# skip spindown if user present  如果用户在场，则跳过停转
		if [ $USER_PRESENT -eq 0 ]; then
			# check against idle timeout  检查空闲超时
			# ge 大于等于
			if [ $(($(date +%s) - ${STAMP[$1]})) -ge ${TIMEOUT[$1]} ]; then
				# spindown disk  停转磁盘
				dev_spindown "$DEV"
			fi
		fi
	else
		# update r/w timestamp  更新读写时间戳
		COUNT[$1]="$COUNT_NEW"
		STAMP[$1]=$(date +%s)
	fi
}

##############################################################   开始   ##########################################################################3
# read config file
if ! [ -r "$CONFIG" ]; then
	echo "error: unable to read config file '$CONFIG', aborting." >&2
	exit 1
else
    source "$CONFIG"
fi

# default watch interval: 300s
# 当变量a为null或为空字符串时则var=b
# var=${a:-b}
readonly CONF_INT=${CONF_INT:-300}
# default spinup read size: 128MiB
readonly CONF_READLEN=${CONF_READLEN:-128}
# default syslog usage: disabled
readonly CONF_SYSLOG=${CONF_SYSLOG:-0}

# check prerequisites   检查先决条件
check_req date hdparm smartctl dd cut grep
# 如果 CONF_HOSTS 非空 则检查 ping
[ -n "$CONF_HOSTS" ] && check_req ping
# 如果 CONF_SYSLOG 等于1 则检查 logger
[ $CONF_SYSLOG -eq 1 ] && check_req logger

# refuse to work without disks defined  拒绝在未定义磁盘的情况下工作
# 如果 CONF_DEV 为0 
if [ -z "$CONF_DEV" ]; then
	echo "error: missing configuration parameter 'CONF_DEV', aborting." >&2
	exit 1
fi

# initialize device arrays   初始化设备数组
# 获取数组长度
DEV_MAX=$((${#CONF_DEV[@]} - 1))
# seq 序列 例如 seq 0 5 序列为 0 1 2 3 4 5
for I in $(seq 0 $DEV_MAX); do
	DEVICES[$I]="$(echo "${CONF_DEV[$I]}" | cut -d '|' -f 1)"
	TIMEOUT[$I]="$(echo "${CONF_DEV[$I]}" | cut -d '|' -f 2)"
done


USER_PRESENT=0
# 使用 CONF_INT 秒 间隔
log "Using ${CONF_INT}s interval"

while true; do

    # 更新在线状态
	update_presence

	for I in $(seq 0 $DEV_MAX); do
		check_dev $I
	done
    # 按检测时间间隔休眠
	sleep $CONF_INT
done
