#!/bin/bash
# Author: Nithish Kumar
# - Collects Docker daemon and Amazon EKS daemon set information on Amazon Linux,
#   Redhat 7, Debian 8.
# - Collects general operating system logs.
# - Optional ability to enable debug mode for the Docker daemon


export LANG="C"
export LC_ALL="C"

# Common options
curdir="$(dirname $0)"
infodir="${curdir}/ekslogsbundle"
info_system="${infodir}/system"
days3=`date -d "-3 days" '+%Y-%m-%d %H:%M'`

# Global options
pkgtype=''  # defined in get_sysinfo
os_name=''  # defined in get_sysinfo
progname='' # defined in parse_options


# Common functions
# ---------------------------------------------------------------------------------------

help()
{
  echo "USAGE: ${progname} [--mode=[brief|debug]]"
  echo "       ${progname} --help"
  echo ""
  echo "OPTIONS:"
  echo "     --mode  Sets the desired mode of the script. For more information,"
  echo "             see the MODES section."
  echo "     --help  Show this help message."
  echo ""
  echo "MODES:"
  echo "     brief       Gathers basic operating system, Docker daemon, and Amazon"
  echo "                 EKS related config files and logs. This is the default mode."
  echo "     debug       Collects 'brief' logs and also enables debug mode for the"
  echo "                 Docker daemon."
  echo "     debug-only  Enables debug mode for the Docker daemon"
}

parse_options() {
  local count="$#"

  progname="$0"

  for i in `seq ${count}`; do
    eval arg=\$$i
    param="`echo ${arg} | awk -F '=' '{print $1}' | sed -e 's|--||'`"
    val="`echo ${arg} | awk -F '=' '{print $2}'`"

    case "${param}" in
      mode)
        eval $param="${val}"
        ;;
      help)
        help && exit 0
        ;;
      *)
        echo "Command not found: '--$param'"
        help && exit 1
        ;;
    esac
  done
}

ok() {
  echo "ok"
}

info() {
  echo "$*"
}

try() {
  local action=$@
  echo -n "Trying to $action... "
}

warning() {
  local reason=$@
  echo "Warning: $reason "
}

fail() {
  echo "failed"
}

failed() {
  local reason=$@
  echo "failed: $reason"
}

die()
{
  echo "ERROR: $*.. exiting..."
  exit 1
}

is_root()
{
  try "check if the script is running as root"

  if [[ "$(id -u)" != "0" ]]; then
    die "This script must be run as root!"

  fi

  ok
}

is_diskfull()
{
  try "check disk space usage"

  threshold=70
  i=2
  result=`df -kh |grep -v "Filesystem" | awk '{ print $5 }' | sed 's/%//g'`

  for percent in ${result}; do
    if [[ "${percent}" -gt "${threshold}" ]]; then
      partition=`df -kh | head -$i | tail -1| awk '{print $1}'`
      warning "${partition} is ${percent}% full, please ensure adequate disk space to collect and store the log files."
    fi
    let i=$i+1
  done

  ok
}

cleanup()
{
  rm -rf ${infodir} >/dev/null 2>&1
  rm -f ${curdir}/ekslogsbundle.tar.gz
}

init() {
  is_root
  try_set_instance_infodir
  get_sysinfo
}

try_set_instance_infodir() {
  try "resolve instance-id"

  if command -v curl > /dev/null; then
    instance_id=$(curl --max-time 3 -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
    if [[ -n "$instance_id" ]]; then
      # Put logs into a directory for this instance.
      infodir="${infodir}/${instance_id}"
      info_system="${infodir}/system"
      echo "$instance_id" | $info_system/instance-id.txt
    else
      warning "unable to resolve instance metadata"
      return 1
    fi
  else
    warning "curl is unavailable for querying"
    return 1
  fi

  ok
}

collect_brief() {
  init
  is_diskfull
  get_common_logs
  get_kernel_logs
  get_mounts_info
  get_selinux_info
  get_iptables_info
  get_pkglist
  get_system_services
  get_docker_info
  get_eks_logs_and_configfiles
  get_containers_info
  get_docker_logs
}

enable_debug() {
  init
  enable_docker_debug
}

pack()
{
  try "archive gathered log information"

  local tar_bin
  tar_bin="`which tar 2>/dev/null`"
  [ -z "${tar_bin}" ] && warning "TAR archiver not found, please install a TAR archiver to create the collection archive. You can still view the logs in the collect folder."

  cd ${curdir}
  ${tar_bin} -cvzf ${infodir}.tar.gz ${infodir} > /dev/null 2>&1

  ok
}

#
# ---------------------------------------------------------------------------------------
get_sysinfo()
{
  try "collect system information"

  res="`/bin/uname -m`"
  [ "${res}" = "amd64" -o "$res" = "x86_64" ] && arch="x86_64" || arch="i386"

  found_file=""
  for f in system-release redhat-release lsb-release debian_version; do
    [ -f "/etc/${f}" ] && found_file="${f}" && break
  done

  case "${found_file}" in
    system-release)
      pkgtype="rpm"
      if grep --quiet "Amazon" /etc/${found_file}; then
        os_name="amazon"
      elif grep --quiet "Red Hat" /etc/${found_file}; then
        os_name="redhat"
      fi
      ;;
    debian_version)
      pkgtype="deb"
      if grep --quiet "8" /etc/${found_file}; then
        os_name="debian"
      fi
      ;;
    lsb-release)
      pkgtype="deb"
      if grep --quiet "Ubuntu 14.04" /etc/${found_file}; then
        os_name="ubuntu14"
      fi
      ;;
    *)
      fail
      die "Unsupported OS detected."
      ;;
  esac

  ok
}

get_mounts_info()
{
  try "get mount points and volume information"
  mkdir -p ${info_system}
  mount > ${info_system}/mounts.txt
  echo "" >> ${info_system}/mounts.txt
  df -h >> ${info_system}/mounts.txt

  if [ -e /sbin/lvs ]; then
    lvs > ${info_system}/lvs.txt
    pvs > ${info_system}/pvs.txt
    vgs > ${info_system}/vgs.txt
  fi

  ok
}

get_selinux_info()
{
  try "check SELinux status"

  enforced="`getenforce 2>/dev/null`"

  [ "${pkgtype}" != "rpm" -o -z "${enforced}" ] \
    && info "not installed" \
    && return

  mkdir -p ${info_system}
  echo -e "SELinux mode:\n    ${enforced}" >  ${info_system}/selinux.txt

  ok
}

get_iptables_info()
{
  try "get iptables list"

  mkdir -p ${info_system}
  /sbin/iptables -nvL -t filter > ${info_system}/iptables-filter.txt
  /sbin/iptables -nvL -t nat  > ${info_system}/iptables-nat.txt

  ok
}

get_common_logs()
{
  try "collect common operating system logs"
  dstdir="${info_system}/var_log"
  mkdir -p ${dstdir}

  for entry in syslog messages aws-routed-eni containers pods cloud-init.log cloud-init-output.log audit; do
    [ -e "/var/log/${entry}" ] && cp -fR /var/log/${entry} ${dstdir}/
  done

  ok
}

get_kernel_logs()
{
  try "collect kernel logs"
  dstdir="${info_system}/kernel"
  mkdir -p "$dstdir"
  if [ -e "/var/log/dmesg" ]; then
    cp -f /var/log/dmesg "$dstdir/dmesg.boot"
  fi
  dmesg > "$dstdir/dmesg.current"
  ok
}

get_docker_logs()
{
  try "collect Docker daemon logs"
  dstdir="${info_system}/docker_log"
  mkdir -p ${dstdir}
  case "${os_name}" in
    amazon)
      if [ -e /bin/journalctl ]; then
         /bin/journalctl -u docker --since "${days3}" > ${dstdir}/docker
      else
         cp /var/log/docker ${dstdir}
      fi
      ;;
    redhat)
      if [ -e /bin/journalctl ]; then
        /bin/journalctl -u docker --since "${days3}" > ${dstdir}/docker
      fi
      ;;
    debian)
      if [ -e /bin/journalctl ]; then
        /bin/journalctl -u docker --since "${days3}" > ${dstdir}/docker
      fi
      ;;
    ubuntu14)
      cp -f /var/log/upstart/docker* ${dstdir}
      ;;
    *)
      warning "The current operating system is not supported."
      ;;
  esac

  ok
}

get_eks_logs_and_configfiles()
{
  try "collect Amazon EKS container agent logs"
  dstdir="${info_system}/eks"

  mkdir -p ${dstdir}
  mkdir -p ${dstdir}
  case "${os_name}" in
    amazon)
      if [ -e /bin/journalctl ]; then
      /bin/journalctl -u kubelet --since "${days3}" > ${dstdir}/kubelet
      /bin/journalctl -u kubeproxy --since "${days3}" > ${dstdir}/kubeproxy
      fi
      cp -r /var/lib/kubelet/kubeconfig ${dstdir}/kubeconfig
      cp -r /etc/systemd/system/kube-proxy.service ${dstdir}/kube-proxy.service
      cp -r /etc/systemd/system/kubelet.service ${dstdir}/kubelet.service
      ;;
    *)
      warning "The current operating system is not supported."
      ;;
  esac

  ok
}

get_pkglist()
{
  try "detect installed packages"

  mkdir -p ${info_system}
  case "${pkgtype}" in
    rpm)
      rpm -qa >${info_system}/pkglist.txt 2>&1
      ;;
    deb)
      dpkg --list > ${info_system}/pkglist.txt 2>&1
      ;;
    *)
      warning "Unknown package type."
      ;;
  esac

  ok
}

get_system_services()
{
  try "detect active system services list"
  mkdir -p ${info_system}
  case "${os_name}" in
    amazon)
      /bin/systemctl list-units > ${info_system}/services.txt 2>&1
      ;;
    debian)
      /bin/systemctl list-units > ${info_system}/services.txt 2>&1
      ;;
    ubuntu14)
      /sbin/initctl list | awk '{ print $1 }' | xargs -n1 initctl show-config > ${info_system}/services.txt 2>&1
      printf "\n\n\n\n" >> ${info_system}/services.txt 2>&1
      /usr/bin/service --status-all >> ${info_system}/services.txt 2>&1
      ;;
    *)
      warning "Unable to determine active services."
      ;;
  esac

  top -b -n 1 > ${info_system}/top.txt 2>&1
  ps fauxwww > ${info_system}/ps.txt 2>&1
  netstat -plant > ${info_system}/netstat.txt 2>&1

  ok
}

get_docker_info()
{
  try "gather Docker daemon information"

  ps -ef |grep dockerd |grep -v grep >> /dev/null
  if [[ "$?" -eq 0 ]]; then
    mkdir -p ${info_system}/docker

    timeout 75 docker info > ${info_system}/docker/docker-info.txt 2>&1 || echo "Timed out, ignoring \"docker info output \" "
    timeout 75 docker ps --all --no-trunc > ${info_system}/docker/docker-ps.txt 2>&1 || echo "Timed out, ignoring \"docker ps --all --no-truc output \" "
    timeout 75 docker images > ${info_system}/docker/docker-images.txt 2>&1 || echo "Timed out, ignoring \"docker images output \" "
    timeout 75 docker version > ${info_system}/docker/docker-version.txt 2>&1 || echo "Timed out, ignoring \"docker version output \" "

    ok

  else
    die "The Docker daemon is not running."
  fi
}

get_containers_info()
{
  try "inspect running Docker containers and gather container data"
    mkdir -p ${info_system}/docker

    for i in `docker ps -q`; do
      docker inspect $i > $info_system/docker/container-$i.txt 2>&1
    done

    ok
}

enable_docker_debug()
{
  try "enable debug mode for the Docker daemon"

  case "${os_name}" in
    amazon)

      if [ -e /etc/sysconfig/docker ] && grep -q "^\s*OPTIONS=\"-D" /etc/sysconfig/docker
      then
        info "Debug mode is already enabled."
      else

        if [ -e /etc/sysconfig/docker ]; then
          echo "OPTIONS=\"-D \$OPTIONS\"" >> /etc/sysconfig/docker

          try "restart Docker daemon to enable debug mode"
          /sbin/service docker restart
        fi

        ok

      fi
      ;;
    *)
      warning "The current operating system is not supported."
      ;;
  esac
}

# --------------------------------------------------------------------------------------------

parse_options $*

[ -z "${mode}" ] && mode="brief"

case "${mode}" in
  brief)
    cleanup
    collect_brief
    pack
    ;;
  debug)
    cleanup
    collect_brief
    enable_debug
    pack
    ;;
  debug-only)
    enable_debug
    ;;
  *)
    help && exit 1
    ;;
esac
