This plans to be a low-resource h.264 video player, which we'll be using to build remote desktop software.

# Requirements
- Use node v12.10.0. v12.14.0 does not work :( :(. It gives an SDL error, lameeee

# How to run
- `tar xzf frames.tar.gz`
- `cd addons/original`
- `yarn install`
- `yarn build`
- `cd ../..`
- Get a .mp4 or raw .h264 video put it in this folder
- Edit `index.js` to point to the file
- Run `node index.js`
