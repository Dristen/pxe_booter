Yoinked from an old StackOverflow comment and adjusted slightly. The script gets your current boot order, sets PXE first and current boot option (which is likely the OS) second. **🛑 It then reboots the server to make sure it is applied correctly.**

## Debian, Ubuntu

```
cd /usr/bin && wget -O pxe.sh https://raw.githubusercontent.com/Dristen/pxe_booter/main/pxe.sh && chmod u+x pxe.sh && sh pxe.sh
```

## CentOS

```
yes | sudo yum install wget && cd /usr/bin && wget -O pxe.sh https://raw.githubusercontent.com/Dristen/pxe_booter/main/pxe_centos.sh && chmod u+x pxe.sh && sh pxe.sh && echo "cd /usr/bin && sh pxe.sh" >> /etc/rc.d/rc.local && chmod +x /etc/rc.d/rc.local && reboot
```

## AlmaLinux

```
sudo yum install wget -y && cd /usr/bin && wget -O pxe.sh https://raw.githubusercontent.com/Dristen/pxe_booter/main/pxe_centos.sh && chmod u+x pxe.sh && sh pxe.sh && echo "cd /usr/bin && sh pxe.sh" >> /etc/rc.d/rc.local && chmod +x /etc/rc.d/rc.local && reboot
```
