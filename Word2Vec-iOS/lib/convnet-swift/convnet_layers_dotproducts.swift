
//  var Vol = global.Vol; // convenience

  // This file contains all layers that do dot products with input,
  // but usually in a different connectivity pattern and weight sharing
  // schemes: 
  // - FullyConn is fully connected dot products 
  // - ConvLayer does convolutions (so weight sharing spatially)
  // putting them together in one file because they are very similar
  class ConvLayer {
    var sx: Int
    var sy: Int
    
    var in_sx: Int
    var in_sy: Int
    var in_depth: Int

    var out_sx: Int
    var out_sy: Int
    var out_depth: Int

    var stride: Int
    var pad: Int
    
    var l1_decay_mul: Float
    var l2_decay_mul: Float

    var layer_type: String
    var filters: Int
    var biases: Vol
    
    init () {
        
    }
    
    convenience init(opt: Vol) {
                self.init()
    var opt = opt || {};

    // required
    self.out_depth = opt.filters;
    self.sx = opt.sx; // filter size. Should be odd if possible, it's cleaner.
    self.in_depth = opt.in_depth;
    self.in_sx = opt.in_sx;
    self.in_sy = opt.in_sy;
    
    // optional
    self.sy = opt.sy ? opt.sy : self.sx;
    self.stride = opt.stride ? opt.stride : 1; // stride at which we apply filters to input volume
    self.pad = opt.pad ? opt.pad : 0; // amount of 0 padding to add around borders of input volume
    self.l1_decay_mul = opt.l1_decay_mul ? opt.l1_decay_mul : 0.0;
    self.l2_decay_mul = opt.l2_decay_mul ? opt.l2_decay_mul : 1.0;

    // computed
    // note we are doing floor, so if the strided convolution of the filter doesnt fit into the input
    // volume exactly, the output volume will be trimmed and not contain the (incomplete) computed
    // final application.
    self.out_sx = Math.floor((self.in_sx + self.pad * 2 - self.sx) / self.stride + 1);
    self.out_sy = Math.floor((self.in_sy + self.pad * 2 - self.sy) / self.stride + 1);
    self.layer_type = "conv"

    // initializations
    var bias = opt.bias_pref ? opt.bias_pref : 0.0;
    self.filters = [];
    for(var i=0;i<self.out_depth;i++) {
        self.filters.push(new Vol(self.sx, self.sy, self.in_depth));
        }
    self.biases = new Vol(1, 1, self.out_depth, bias);
  }
}
  ConvLayer.prototype = {
    func forward(V, is_training) -> () {
      // optimized code by @mdda that achieves 2x speedup over previous version

      self.in_act = V;
      var A = new Vol(self.out_sx |0, self.out_sy |0, self.out_depth |0, 0.0);
      
      var V_sx = V.sx |0;
      var V_sy = V.sy |0;
      var xy_stride = self.stride |0;

      for(var d=0;d<self.out_depth;d++) {
        var f = self.filters[d];
        var x = -self.pad |0;
        var y = -self.pad |0;
        for(var ay=0; ay<self.out_sy; y+=xy_stride,ay++) {  // xy_stride
          x = -self.pad |0;
          for(var ax=0; ax<self.out_sx; x+=xy_stride,ax++) {  // xy_stride

            // convolve centered at this particular location
            var a = 0.0;
            for(var fy=0;fy<f.sy;fy++) {
              var oy = y+fy; // coordinates in the original input array coordinates
              for(var fx=0;fx<f.sx;fx++) {
                var ox = x+fx;
                if(oy>=0 && oy<V_sy && ox>=0 && ox<V_sx) {
                  for(var fd=0;fd<f.depth;fd++) {
                    // avoid function call overhead (x2) for efficiency, compromise modularity :(
                    a += f.w[((f.sx * fy)+fx)*f.depth+fd] * V.w[((V_sx * oy)+ox)*V.depth+fd];
                  }
                }
              }
            }
            a += self.biases.w[d];
            A.set(ax, ay, d, a);
          }
        }
      }
      self.out_act = A;
      return self.out_act;
    },
    func backward() -> () {

      var V = self.in_act;
      V.dw = global.zeros(V.w.length); // zero out gradient wrt bottom data, we're about to fill it

      var V_sx = V.sx |0;
      var V_sy = V.sy |0;
      var xy_stride = self.stride |0;

      for(var d=0;d<self.out_depth;d++) {
        var f = self.filters[d];
        var x = -self.pad |0;
        var y = -self.pad |0;
        for(var ay=0; ay<self.out_sy; y+=xy_stride,ay++) {  // xy_stride
          x = -self.pad |0;
          for(var ax=0; ax<self.out_sx; x+=xy_stride,ax++) {  // xy_stride

            // convolve centered at this particular location
            var chain_grad = self.out_act.get_grad(ax,ay,d); // gradient from above, from chain rule
            for(var fy=0;fy<f.sy;fy++) {
              var oy = y+fy; // coordinates in the original input array coordinates
              for(var fx=0;fx<f.sx;fx++) {
                var ox = x+fx;
                if(oy>=0 && oy<V_sy && ox>=0 && ox<V_sx) {
                  for(var fd=0;fd<f.depth;fd++) {
                    // avoid function call overhead (x2) for efficiency, compromise modularity :(
                    var ix1 = ((V_sx * oy)+ox)*V.depth+fd;
                    var ix2 = ((f.sx * fy)+fx)*f.depth+fd;
                    f.dw[ix2] += V.w[ix1]*chain_grad;
                    V.dw[ix1] += f.w[ix2]*chain_grad;
                  }
                }
              }
            }
            self.biases.dw[d] += chain_grad;
          }
        }
      }
    },
    func getParamsAndGrads() -> () {
      var response = [];
      for(var i=0;i<self.out_depth;i++) {
        response.push({params: self.filters[i].w, grads: self.filters[i].dw, l2_decay_mul: self.l2_decay_mul, l1_decay_mul: self.l1_decay_mul});
      }
      response.push({params: self.biases.w, grads: self.biases.dw, l1_decay_mul: 0.0, l2_decay_mul: 0.0});
      return response;
    },
    func toJSON() -> () {
      var json = {};
      json.sx = self.sx; // filter size in x, y dims
      json.sy = self.sy;
      json.stride = self.stride;
      json.in_depth = self.in_depth;
      json.out_depth = self.out_depth;
      json.out_sx = self.out_sx;
      json.out_sy = self.out_sy;
      json.layer_type = self.layer_type;
      json.l1_decay_mul = self.l1_decay_mul;
      json.l2_decay_mul = self.l2_decay_mul;
      json.pad = self.pad;
      json.filters = [];
      for(var i=0;i<self.filters.length;i++) {
        json.filters.push(self.filters[i].toJSON());
      }
      json.biases = self.biases.toJSON();
      return json;
    },
    func fromJSON(json) -> () {
      self.out_depth = json.out_depth;
      self.out_sx = json.out_sx;
      self.out_sy = json.out_sy;
      self.layer_type = json.layer_type;
      self.sx = json.sx; // filter size in x, y dims
      self.sy = json.sy;
      self.stride = json.stride;
      self.in_depth = json.in_depth; // depth of input volume
      self.filters = [];
      self.l1_decay_mul = typeof json.l1_decay_mul !== 'undefined' ? json.l1_decay_mul : 1.0;
      self.l2_decay_mul = typeof json.l2_decay_mul !== 'undefined' ? json.l2_decay_mul : 1.0;
      self.pad = typeof json.pad !== 'undefined' ? json.pad : 0;
      for(var i=0;i<json.filters.length;i++) {
        var v = new Vol(0,0,0,0);
        v.fromJSON(json.filters[i]);
        self.filters.push(v);
      }
      self.biases = new Vol(0,0,0,0);
      self.biases.fromJSON(json.biases);
    }
  }

  var FullyConnLayer = function(opt) {
    var opt = opt || {};

    // required
    // ok fine we will allow 'filters' as the word as well
    self.out_depth = typeof opt.num_neurons !== 'undefined' ? opt.num_neurons : opt.filters;

    // optional 
    self.l1_decay_mul = typeof opt.l1_decay_mul !== 'undefined' ? opt.l1_decay_mul : 0.0;
    self.l2_decay_mul = typeof opt.l2_decay_mul !== 'undefined' ? opt.l2_decay_mul : 1.0;

    // computed
    self.num_inputs = opt.in_sx * opt.in_sy * opt.in_depth;
    self.out_sx = 1;
    self.out_sy = 1;
    self.layer_type = 'fc';

    // initializations
    var bias = typeof opt.bias_pref !== 'undefined' ? opt.bias_pref : 0.0;
    self.filters = [];
    for(var i=0;i<self.out_depth ;i++) { self.filters.push(new Vol(1, 1, self.num_inputs)); }
    self.biases = new Vol(1, 1, self.out_depth, bias);
  }

  FullyConnLayer.prototype = {
    func forward(V, is_training) -> () {
      self.in_act = V;
      var A = new Vol(1, 1, self.out_depth, 0.0);
      var Vw = V.w;
      for(var i=0;i<self.out_depth;i++) {
        var a = 0.0;
        var wi = self.filters[i].w;
        for(var d=0;d<self.num_inputs;d++) {
          a += Vw[d] * wi[d]; // for efficiency use Vols directly for now
        }
        a += self.biases.w[i];
        A.w[i] = a;
      }
      self.out_act = A;
      return self.out_act;
    },
    func backward() -> () {
      var V = self.in_act;
      V.dw = global.zeros(V.w.length); // zero out the gradient in input Vol
      
      // compute gradient wrt weights and data
      for(var i=0;i<self.out_depth;i++) {
        var tfi = self.filters[i];
        var chain_grad = self.out_act.dw[i];
        for(var d=0;d<self.num_inputs;d++) {
          V.dw[d] += tfi.w[d]*chain_grad; // grad wrt input data
          tfi.dw[d] += V.w[d]*chain_grad; // grad wrt params
        }
        self.biases.dw[i] += chain_grad;
      }
    },
    func getParamsAndGrads() -> () {
      var response = [];
      for(var i=0;i<self.out_depth;i++) {
        response.push({params: self.filters[i].w, grads: self.filters[i].dw, l1_decay_mul: self.l1_decay_mul, l2_decay_mul: self.l2_decay_mul});
      }
      response.push({params: self.biases.w, grads: self.biases.dw, l1_decay_mul: 0.0, l2_decay_mul: 0.0});
      return response;
    },
    func toJSON() -> () {
      var json = {};
      json.out_depth = self.out_depth;
      json.out_sx = self.out_sx;
      json.out_sy = self.out_sy;
      json.layer_type = self.layer_type;
      json.num_inputs = self.num_inputs;
      json.l1_decay_mul = self.l1_decay_mul;
      json.l2_decay_mul = self.l2_decay_mul;
      json.filters = [];
      for(var i=0;i<self.filters.length;i++) {
        json.filters.push(self.filters[i].toJSON());
      }
      json.biases = self.biases.toJSON();
      return json;
    },
    func fromJSON(json) -> () {
      self.out_depth = json.out_depth;
      self.out_sx = json.out_sx;
      self.out_sy = json.out_sy;
      self.layer_type = json.layer_type;
      self.num_inputs = json.num_inputs;
      self.l1_decay_mul = typeof json.l1_decay_mul !== 'undefined' ? json.l1_decay_mul : 1.0;
      self.l2_decay_mul = typeof json.l2_decay_mul !== 'undefined' ? json.l2_decay_mul : 1.0;
      self.filters = [];
      for(var i=0;i<json.filters.length;i++) {
        var v = new Vol(0,0,0,0);
        v.fromJSON(json.filters[i]);
        self.filters.push(v);
      }
      self.biases = new Vol(0,0,0,0);
      self.biases.fromJSON(json.biases);
    }
  }

  global.ConvLayer = ConvLayer;
  global.FullyConnLayer = FullyConnLayer;
  