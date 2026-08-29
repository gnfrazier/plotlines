import os
import sys

# The spike modules import each other by bare name (analyze imports bands, etc.),
# matching how the other spikes are laid out. Put the spike root on the path.
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
