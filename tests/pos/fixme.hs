module Foo where

{-@  
data List a <p :: x0:a -> x1:a -> Bool>  
  = Nil 
  | MYCONOS (h :: a) (t :: List <p> (a <p h>))
@-}

data List a = Nil | MYCONOS a (List a)



foo x = 8 

