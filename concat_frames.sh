set -ex

rm -rf frames
tar xzf frames.tar.gz

echo "Now create h264 file silently!"
set +x
cat `ls frames | sort -V | awk '{print "frames/" $0}' | tr '\n' ' '` > hello.h264
