module spec GHC.Prim where

assume GHC.Types.I# :: x:GHC.Prim.Int# -> {v: Int | v = (x :: Int) }   
assume GHC.Prim.+#  :: x:GHC.Prim.Int# -> y:GHC.Prim.Int# -> {v: GHC.Prim.Int# | v = x + y}
assume GHC.Prim.-#  :: x:GHC.Prim.Int# -> y:GHC.Prim.Int# -> {v: GHC.Prim.Int# | v = x - y}