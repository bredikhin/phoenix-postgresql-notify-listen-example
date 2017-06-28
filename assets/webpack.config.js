var resolve = require('path').resolve;
var ExtractTextPlugin = require('extract-text-webpack-plugin');
var CopyWebpackPlugin = require('copy-webpack-plugin');

module.exports = {
  entry: ['./js/app.js', './css/app.css'],
  output: {
    path: resolve('./../priv/static'),
    filename: 'js/app.js'
  },
  module: {
    rules: [{
      test: /\.js$/,
      exclude: /node_modules/,
      loader: 'babel-loader',
      options: {
        presets: ['es2015']
      }
    },
    {
      test: /\.css$/,
      loader: ExtractTextPlugin.extract({fallback: 'style-loader', use: 'css-loader'})
    },
    {
      test: /\.elm$/,
      exclude: [/elm-stuff/, /node_modules/],
      loader:  'elm-webpack-loader?cwd=' + resolve('./../elm'),
    }]
  },
  plugins: [
    new ExtractTextPlugin('css/app.css'),
    new CopyWebpackPlugin([{from: './static'}])
  ],
  resolve: {
    modules: ['node_modules', resolve('./../deps')]
  }
};
