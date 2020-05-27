import System.Environment.Blank
import System.Process

main :: IO ()
main = do
  setEnv "INSIDE_ARGS" "1 2 3 4" True
  callProcess "sh" ["-e", "script.sh"]
