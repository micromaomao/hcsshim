package verity

import (
	"context"
	"fmt"
	"os"

	"github.com/Microsoft/hcsshim/ext4/dmverity"
	"github.com/Microsoft/hcsshim/ext4/tar2ext4"
	"github.com/Microsoft/hcsshim/internal/log"
	"github.com/Microsoft/hcsshim/internal/protocol/guestresource"
	"github.com/pkg/errors"
	"github.com/sirupsen/logrus"
)

func WriteKMsg(msg string) {
	kmsg, err := os.OpenFile("/dev/kmsg", os.O_WRONLY, 0)
	if err != nil {
		return
	}
	kmsg.WriteString(msg)
	kmsg.Close()
}

// fileSystemSize retrieves ext4 fs SuperBlock and returns the file system size and block size
func fileSystemSize(vhdPath string) (int64, int, error) {
	var vhd *os.File
	// tries := 0
	// maxTries := 100
	for {
		var err error
		vhd, err = os.OpenFile(vhdPath, os.O_RDONLY, 0)
		if err != nil {
			// WriteKMsg(fmt.Sprintf("verity: failed to open vhd: %v - attempt %d / %d\n", err, tries+1, maxTries))
			WriteKMsg(fmt.Sprintf("verity: failed to open vhd: %v\n", err))
			return 0, 0, err
			// if tries < maxTries {
			// 	tries++
			// 	time.Sleep(200 * time.Millisecond)
			// 	continue
			// } else {
			// 	return 0, 0, err
			// }
		} else {
			break
		}
	}
	defer vhd.Close()

	return tar2ext4.Ext4FileSystemSize(vhd)
}

// ReadVeritySuperBlock reads ext4 super block for a given VHD to then further read the dm-verity super block
// and root hash
func ReadVeritySuperBlock(ctx context.Context, layerPath string) (*guestresource.DeviceVerityInfo, error) {
	// dm-verity information is expected to be appended, the size of ext4 data will be the offset
	// of the dm-verity super block, followed by merkle hash tree
	ext4SizeInBytes, ext4BlockSize, err := fileSystemSize(layerPath)
	if err != nil {
		return nil, err
	}

	dmvsb, err := dmverity.ReadDMVerityInfo(layerPath, ext4SizeInBytes)
	if err != nil {
		return nil, errors.Wrap(err, "failed to read dm-verity super block")
	}
	log.G(ctx).WithFields(logrus.Fields{
		"layerPath":     layerPath,
		"rootHash":      dmvsb.RootDigest,
		"algorithm":     dmvsb.Algorithm,
		"salt":          dmvsb.Salt,
		"dataBlocks":    dmvsb.DataBlocks,
		"dataBlockSize": dmvsb.DataBlockSize,
	}).Debug("dm-verity information")

	return &guestresource.DeviceVerityInfo{
		Ext4SizeInBytes: ext4SizeInBytes,
		BlockSize:       ext4BlockSize,
		RootDigest:      dmvsb.RootDigest,
		Algorithm:       dmvsb.Algorithm,
		Salt:            dmvsb.Salt,
		Version:         int(dmvsb.Version),
		SuperBlock:      true,
	}, nil
}
