#!/bin/sh -e
#
# Copyright (c) 2013-2015 Robert Nelson <robertcnelson@gmail.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

#Based off:
#https://github.com/beagleboard/meta-beagleboard/blob/master/meta-beagleboard-extras/recipes-support/usb-gadget/gadget-init/g-ether-load.sh

#eMMC flasher just exited single user mode via: [exec /sbin/init]
#as we can't shudown properly in single user mode..
unset are_we_flasher
are_we_flasher=$(grep init-eMMC-flasher /proc/cmdline || true)
if [ ! "x${are_we_flasher}" = "x" ] ; then
	halt
	exit
fi

if [ -f /etc/rcn-ee.conf ] ; then
	. /etc/rcn-ee.conf
fi

eeprom="/sys/bus/i2c/devices/0-0050/eeprom"

if [ "x${abi}" = "x" ] ; then
#taken care by the init flasher
	#Flash BeagleBone Black's eeprom:
	if [ -f /boot/uboot/flash-eMMC.txt ] ; then
		eeprom_location=$(ls /sys/devices/ocp.*/44e0b000.i2c/i2c-0/0-0050/eeprom 2> /dev/null)
		eeprom_header=$(hexdump -e '8/1 "%c"' ${eeprom} -s 5 -n 3)
		if [ "x${eeprom_header}" = "x335" ] ; then
			echo "Valid EEPROM header found"
		else
			echo "Invalid EEPROM header detected"
			if [ -f /opt/scripts/device/bone/bbb-eeprom.dump ] ; then
				if [ ! "x${eeprom_location}" = "x" ] ; then
					echo "Adding header to EEPROM"
					dd if=/opt/scripts/device/bone/bbb-eeprom.dump of=${eeprom_location}
					sync
					#We have to reboot, to load eMMC cape
					reboot
					#We shouldnt hit this...
					exit
				fi
			fi
		fi
	fi
fi

SERIAL_NUMBER="0123456789"
ISBLACK=""
PRODUCT="am335x_evm"
manufacturer="Circuitco"
if [ -f ${eeprom} ] ; then
	SERIAL_NUMBER=$(hexdump -e '8/1 "%c"' ${eeprom} -s 14 -n 2)-$(hexdump -e '8/1 "%c"' ${eeprom} -s 16 -n 12)
	ISBLACK=$(hexdump -e '8/1 "%c"' ${eeprom} -s 8 -n 4)

	PRODUCT="BeagleBone"
	if [ "x${ISBLACK}" = "xBBBK" ] || [ "x${ISBLACK}" = "xBNLT" ] ; then
		PRODUCT="BeagleBoneBlack"
	fi
fi

mac_address="/proc/device-tree/ocp/ethernet@4a100000/slave@4a100200/mac-address"
if [ -f ${mac_address} ] ; then
	cpsw_0_mac=$(hexdump -v -e '1/1 "%02X" ":"' ${mac_address} | sed 's/.$//')
else
	#todo: generate random mac... (this is a development tre board in the lab...)
	cpsw_0_mac="1c:ba:8c:a2:ed:68"
fi

mac_address="/proc/device-tree/ocp/ethernet@4a100000/slave@4a100300/mac-address"
if [ -f ${mac_address} ] ; then
	cpsw_1_mac=$(hexdump -v -e '1/1 "%02X" ":"' ${mac_address} | sed 's/.$//')
else
	#todo: generate random mac...
	cpsw_1_mac="1c:ba:8c:a2:ed:69"
fi

unset root_drive
root_drive="$(cat /proc/cmdline | sed 's/ /\n/g' | grep root=UUID= | awk -F 'root=' '{print $2}' || true)"
if [ ! "x${root_drive}" = "x" ] ; then
	root_drive="$(/sbin/findfs ${root_drive} || true)"
else
	root_drive="$(cat /proc/cmdline | sed 's/ /\n/g' | grep root= | awk -F 'root=' '{print $2}' || true)"
fi

#In a single partition setup, dont load g_multi, as we could trash the linux file system...
if [ "x${root_drive}" = "x/dev/mmcblk0p1" ] || [ "x${root_drive}" = "x/dev/mmcblk1p1" ] ; then
	if [ -f /usr/sbin/udhcpd ] || [ -f /usr/sbin/dnsmasq ] ; then
		#Make sure (# CONFIG_USB_ETH_EEM is not set), otherwise this shows up as "usb0" instead of ethX on host pc..
		modprobe g_ether iSerialNumber=${SERIAL_NUMBER} iManufacturer=${manufacturer} iProduct=${PRODUCT} host_addr=${cpsw_1_mac} || true
	else
		#serial:
		modprobe g_serial || true
	fi
else
	boot_drive="${root_drive%?}1"
	modprobe g_multi file=${boot_drive} cdrom=0 ro=0 stall=0 removable=1 nofua=1 iSerialNumber=${SERIAL_NUMBER} iManufacturer=${manufacturer} iProduct=${PRODUCT} host_addr=${cpsw_1_mac} || true
fi

sleep 3

#Wheezy Image:
if [ -f /etc/default/udhcpd ] ; then
	unset udhcp_disabled
	udhcp_disabled=$(grep \#DHCPD_ENABLED /etc/default/udhcpd || true)
	if [ "x${udhcp_disabled}" = "x" ] ; then
		sed -i -e 's:DHCPD_ENABLED="no":#DHCPD_ENABLED="no":g' /etc/default/udhcpd
	fi
fi

if [ -f /etc/udhcpd.conf ] ; then
	#Distro default...
	unset deb_udhcpd
	deb_udhcpd=$(grep Sample /etc/udhcpd.conf || true)
	if [ ! "x${deb_udhcpd}" = "x" ] ; then
		mv /etc/udhcpd.conf /etc/udhcpd.conf.bak

		echo "start      192.168.7.1" > /etc/udhcpd.conf
		echo "end        192.168.7.1" >> /etc/udhcpd.conf
		echo "interface  usb0" >> /etc/udhcpd.conf
		echo "max_leases 1" >> /etc/udhcpd.conf
		echo "option subnet 255.255.255.252" >> /etc/udhcpd.conf
	fi
	/etc/init.d/udhcpd restart

	/sbin/ifconfig usb0 192.168.7.2 netmask 255.255.255.252 || true
	/usr/sbin/udhcpd -S /etc/udhcpd.conf
fi

#Jessie Image:
if [ -f /etc/dnsmasq.d/usb0-dhcp ] ; then
	/sbin/ifconfig usb0 192.168.7.2 netmask 255.255.255.252 || true
	systemctl restart dnsmasq
fi

eth0_addr=$(ip addr list eth0 |grep "inet " |cut -d' ' -f6|cut -d/ -f1 2>/dev/null || true)
usb0_addr=$(ip addr list usb0 |grep "inet " |cut -d' ' -f6|cut -d/ -f1 2>/dev/null || true)
wlan0_addr=$(ip addr list wlan0 |grep "inet " |cut -d' ' -f6|cut -d/ -f1 2>/dev/null || true)

sed -i -e '/Address/d' /etc/issue

if [ ! "x${eth0_addr}" = "x" ] ; then
	echo "The IP Address for eth0 is: ${eth0_addr}" >> /etc/issue
fi
if [ ! "x${wlan0_addr}" = "x" ] ; then
	echo "The IP Address for wlan0 is: ${wlan0_addr}" >> /etc/issue
fi
if [ ! "x${usb0_addr}" = "x" ] ; then
	echo "The IP Address for usb0 is: ${usb0_addr}" >> /etc/issue
fi

if [ "x${abi}" = "x" ] ; then
#taken care by the init flasher
	if [ -f /boot/uboot/flash-eMMC.txt ] ; then
		if [ ! -d /boot/uboot/debug/ ] ; then
			mkdir -p /boot/uboot/debug/ || true
		fi

		if [ -f /opt/scripts/tools/beaglebone-black-eMMC-flasher.sh ] ; then
			/bin/bash /opt/scripts/tools/beaglebone-black-eMMC-flasher.sh >/boot/uboot/debug/flash-eMMC.log 2>&1
		fi
	fi
fi

if [ "x${abi}" = "x" ] ; then
#Taken care by:
#https://github.com/RobertCNelson/omap-image-builder/blob/master/target/init_scripts/generic-debian.sh#L51
	if [ -f /resizerootfs ] ; then
		if [ ! -d /boot/debug/ ] ; then
			mkdir -p /boot/debug/ || true
		fi

		drive=$(cat /resizerootfs)
		if [ "x${drive}" = "x" ] ; then
			drive="/dev/mmcblk0"
		fi

		#FIXME: only good for two partition "/dev/mmcblkXp2" setups...
		resize2fs ${drive}p2 >/boot/debug/resize.log 2>&1
		rm -rf /resizerootfs || true
	fi
fi

#
