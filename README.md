This plans to be a low-resource h.264 video player, which we'll be using to build remote desktop software.

# Requirements
- Use node v12.10.0. v12.14.0 does not work :( :(. It gives an SDL error, lameeee
- You need SDL2. `brew install sdl2` should work. You may have to do something about linking headers -- look at the output of this command.
- You also need to install [yarn](https://yarnpkg.com/lang/en/docs/install/#mac-stable)

# How to run
- `tar xzf frames.tar.gz`
- `cd addons/fast`
- `yarn install`
- `yarn build`
- `cd ../..`
- Run `node index.js`
