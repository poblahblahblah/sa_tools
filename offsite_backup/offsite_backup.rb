#!/usr/bin/ruby -w
require 'facter'
require 'fileutils'
require 'logger'
require 'net/smtp'
require 'yaml'

# TODO:
# * add some logging
# * move password to a file
# * add an alert (email for now) for files that fail to:
#   * gzip and encrypt properly
#   * tar and split correctly
# * I thought about adding threading, but with so few cores, but
#   with pigz already spreading it's load across all of the cores
#   it doesn't really seem like it will be all that helpful.

# logging and error stuffs:
$errors = []
config  = File.open("/data/svc/ops/offsite_backup/config.yml")
debug   = true
$logger = Logger.new('/data/svc/ops/logs/offsite_backup.log')

$logger.info("begin offline_backup")
$logger.debug("Section 1 Start") if debug == true

# we're going to pull all partitions mount points that are mounted
# where we mount only the backups disks. We'll want to iterate over
# this list of mount points later on when we split up the archive.
Facter.loadfacts
destination_disks = []
Facter.partitions.split(',').each {|x| destination_disks << `df #{x}`.split[-1] if `df #{x}`.split[-1] =~ /^\/mnt\/disks/}

$logger.debug("Section 2 Start") if debug == true

# we'll want to create a file on each disk with the original mount
# point, this way if we have to string things back together, we'll
# know in which order the split tar archive was created.
destination_disks.each do |d|
  `touch #{d}/#{d.gsub('/', '_')}` if !File.exist?("#{d}/#{d.gsub('/', '_')}")
end

# define some methods
# encrypt and gzip
def encrypt_and_gzip(file_list, scratch_dir)
  # we'll want to basically run through every file in the file_list
  # array, encrypt them and dump them to the output scratch_dir
  file_list.each do |x|
    files       = []
    directories = []
    files       << x if !File.directory?(x)
    directories << x if File.directory?(x)
    FileUtils.mkdir_p(scratch_dir + '/' + File.dirname(x)) if !File.exist?(scratch_dir + '/' + File.dirname(x))

    files.each do |f|
      out_file = scratch_dir + f
      # I guess it's worth noting that we are using pigz for compression
      # in an attempt to speed things up a bit.
      if system("/usr/bin/pigz -9 -c #{x} | /usr/bin/openssl enc -aes-256-cbc -salt -out #{out_file}.enc -pass pass:test") == false
      #if system("/usr/bin/openssl enc -aes-256-cbc -salt -out #{out_file}.enc -pass pass:test") == false
        # TODO
        # do some recovery
        $logger.error("could not gzip and/or encrypt #{x}")
      end
    end
  end
end

# tar and split
def tar_and_split(archive_name, source, destination_disks)
  # join the destination_disks array into a string that tar can use
  # to split up the archives automatically. If a disk is full it should
  # just skip the disk. This can also create irregular sized files, but
  # I don't think we should really care that much.
  tar_dest_list = ""
  destination_disks.each do |x|
    if `df #{x} | grep #{x}`.split[3].to_i > 1024
      tar_dest_list << "--file=#{x}/#{archive_name}.tar "
    end
  end

  # I guess it's nice that tar makes it fairly simple to split up archives
  # to different disks automatically.
  if system("/bin/tar -c -M #{tar_dest_list} #{source} 2>&1 > /dev/null") == false
    # TODO
    # do some recovery
    $logger.error("could not create tar for #{archive_name}")
  end
end

# cleanup scratch space
def cleanup_scratch(scratch_dir)
  FileUtils.rm_rf(scratch_dir)
end

$logger.debug("Section 3 Start") if debug == true

YAML.load_documents(config) do |entry|
  entry.each_pair do |k,v|
    $logger.info("Got config for #{k}")
    file_list   = Dir.glob(v['source_dir'] + '/' + v['file_glob'])
    scratch_dir = "/tmp/scratch/#{k}"
    
    $logger.info("Beginning encrypt_and_gzip for #{k}")
    encrypt_and_gzip(file_list, scratch_dir)

    $logger.info("Beginning tar_and_split for #{k}")
    tar_and_split("#{k}", scratch_dir, destination_disks)

    $logger.info("Cleaning up scratch space for #{k}")
    cleanup_scratch(scratch_dir)

    $logger.info("offline_backup complete for #{k}")
  end
end

$logger.info("end offline_backup run")
