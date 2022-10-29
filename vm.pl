#!/usr/bin/perl

use v5.10;
use strict;
use warnings;

use Cwd qw(abs_path);
use Digest::MD5 qw(md5);
use Fcntl qw(FD_CLOEXEC F_GETFD F_SETFD);
use File::Basename qw(dirname);
use File::Temp;
use File::Which qw(which);
use Getopt::Std qw(getopts);
use POSIX qw(uname dup dup2);

my %arches = (
	qemu => {
		'arm64', 'aarch64',
	},
	alpine => {
		'arm64', 'aarch64',
	},
	debian => {
		'x86_64', 'amd64',
	},
);

my $arch = uname;
sub archify($){
	my $x = shift or die;
	$arches{$x}->{$arch} || $arch;
}

$ENV{PATH} .= ":/opt/socket_vmnet/bin:/opt/homebrew/bin:/usr/local/bin";

my %opts = (
	m => 4096,
	c => 1,
	a => archify('qemu'),
	g => 0,
	d => 0,
);

my $debian = archify 'debian';
my $alpine = archify 'alpine';
my $usage = qq'
Usage: $0 [opts] <qcow2-or-ISO-images>

Options:
  -m <memory>  megabytes of ram to configure (default: $opts{m})
  -c <cores>   number of cpu cores to configure (default: $opts{c})
  -a <arch>    qemu system arch to emulate (default: $opts{a})
  -g           enable graphics instead of serial console (default: no)
  -d           dump generated qemu-system-$opts{a} command and exit

Notes:
  # debian ships serial-console-friendly qcow2 images
  curl -L https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-nocloud-$debian.qcow2 > debian.qcow2
  qemu-img resize debian.qcow2 40G
  $0 debian.qcow2

  # alpine ships serial-console-friendly installer iso images
  curl -L https://dl-cdn.alpinelinux.org/alpine/v3.16/releases/$alpine/alpine-virt-3.16.2-$alpine.iso > alpine.iso
  qemu-img create -f qcow2 alpine.qcow2 40G
  $0 alpine.qcow2 alpine.iso
  # once logged in, run:
  setup-alpine

  # compact an offline qcow2:
  mv disk.qcow2 disk.qcow2.bak
  qemu-img convert -O qcow2 disk.qcow2.bak disk.qcow2

';

getopts('m:c:a:gd', \%opts) or die $usage;
die $usage unless @ARGV;

# generate a MAC address from the provided disk paths
my $mac = substr(md5(join '\0', @ARGV), -6);
substr($mac,0,1) &= "\xfe"; # clear the reserved multicast bit
$mac = join ':', map { sprintf "%02x", $_ } unpack 'C*', $mac;

my %config = (
	MEM => $opts{m},
	CORES => $opts{c},
	ARCH => $opts{a},
	MAC => $mac,
);

my @cmd = grep { length } map { s/%(\w+)%/$config{$1}/g; $_; } split /\s+/, q{
	qemu-system-%ARCH%
	-accel hvf
	-cpu host
	-echr 7
	-m %MEM%
	-smp %CORES%
	-device virtio-balloon
	-device virtio-scsi-pci,id=scsi0
};

if(which 'socket_vmnet_client'){
	unshift @cmd, qw(socket_vmnet_client /var/run/socket_vmnet);
	push @cmd, grep { length } map { s/%(\w+)%/$config{$1}/g; $_; } split /\s+/, q{
		-device virtio-net-pci,netdev=net0,mac=%MAC%
		-netdev socket,id=net0,fd=3
	};
}

push @cmd, '-nographic' unless $opts{g};
my $tmp;
if($opts{a} eq 'aarch64'){
	# unpack bundled QEMU_EFI.fd on the fly
	$tmp = File::Temp->new();
	unlink $tmp->filename;

	# fd 3 is reserved for use by socket_vmnet_client above
	die if $tmp->fileno == 3;
	
	my $fl = fcntl($tmp, F_GETFD, 0);
	fcntl($tmp, F_SETFD, $fl & (~FD_CLOEXEC)) or die "Can't set flags: $!\n";

	my $stdout = dup(1) or die $!;
	dup2($tmp->fileno, 1) or die $!;

	open XZ, '|-', "base64 -d | xz -d" or die $!;
	while(<DATA>){
		chomp;
		print XZ;
	}
	close XZ;

	push @cmd, qw(
		-machine virt
		-bios /dev/fd/
	);
	$cmd[-1] .= $tmp->fileno;

	dup2($stdout, 1);
	POSIX::close($stdout);
}	

my $i = 0;
foreach my $disk (@ARGV){
	my @d;
	if($disk =~ m/\.iso$/i){
		@d = ( # attach *.iso as cdrom
			"-device",
			"scsi-cd,drive=disk$i,bus=scsi0.0,lun=$i",
			"-drive",
			"file=$disk,if=none,format=raw,id=disk$i",
		);
	}else{
		@d = ( # TODO: inspect file header and/or extension to determine image type
			"-device",
			"scsi-hd,drive=disk$i,bus=scsi0.0,lun=$i",
			"-drive",
			"file=$disk,if=none,format=qcow2,discard=unmap,cache=none,id=disk$i",
		);
	}
	push @cmd, @d;
	$i++;
}
if($opts{d}){
	foreach my $a (@cmd){
		print $a;
		print substr($a, 0, 1) eq "-" ? " " : "\n";
	}
	exit 1;
}
exec { $cmd[0] } @cmd or die @cmd;
__DATA__
