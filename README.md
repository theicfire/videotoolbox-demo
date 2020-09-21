This prints out the backing scale of wherever a newly created window is located.

# Requirements
- You need SDL2. `brew install sdl2` should work. You may have to do something about linking headers -- look at the output of this command.


# How to run via node
- Use node v12.10.0. v12.14.0 does not work :( :(. It gives an SDL error, lameeee
- Run `node index.js`

# How to build
There's a prebuilt version, but if you want to build the code this is how:
- Install [yarn](https://yarnpkg.com/lang/en/docs/install/#mac-stable)
- Run `yarn install` inside of addons/vapp
- Run `yarn build`
