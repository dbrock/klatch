FROM base
RUN apt-get -y update
RUN apt-get -y install haskell-platform
RUN cabal update
ADD / /usr/src/klatch
RUN cd /usr/src/klatch && cabal install --only-dependencies
RUN cd /usr/src/klatch && cabal install
